"""Write portable USB sticks and add personal setup bundles, without publishing credentials."""

import argparse
import base64
import json
import os
from pathlib import Path
import platform
import plistlib
import shlex
import shutil
import subprocess
import sys

from prepare_target import validate_identity
from provisioning import encrypt_for_host, public_key


def run(*args, **kwargs):
    return subprocess.run(list(map(str, args)), check=True, **kwargs)


def codex_credentials(home, email):
    path = home / "auth.json"
    if not path.is_file():
        raise ValueError("Sign in to the dedicated installer Codex profile first")
    auth = json.loads(path.read_text())
    tokens = auth.get("tokens") or {}
    if not tokens.get("refresh_token") or not tokens.get("access_token"):
        raise ValueError("A refreshable ChatGPT/Codex login is required")
    try:
        identity = json.loads(base64.urlsafe_b64decode(tokens["id_token"].split(".")[1] + "==="))
    except (KeyError, ValueError, IndexError):
        raise ValueError("Cannot identify the Codex account") from None
    if identity.get("email", "").casefold() != email.casefold():
        raise ValueError("The signed-in Codex account does not match --email")
    run(
        "codex",
        "-c",
        'cli_auth_credentials_store="file"',
        "login",
        "status",
        env={**os.environ, "CODEX_HOME": str(home)},
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return auth


def prepare_identity(args, state):
    validate_identity(args.username, args.hostname, "other")
    login = state / "codex-login"
    login.mkdir(exist_ok=True, mode=0o700)
    if not (login / "auth.json").exists():
        print(
            "Sign in to Codex for the new PC. Your Mac's existing login stays separate.", flush=True
        )
        run(
            "codex",
            "-c",
            'cli_auth_credentials_store="file"',
            "login",
            env={**os.environ, "CODEX_HOME": str(login)},
        )
    accounts = {"codex": codex_credentials(login, args.email)}
    key = state / "ssh_host_ed25519_key"
    if not key.exists():
        run("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", args.hostname, "-f", key)
    key.chmod(0o600)
    recipient = public_key(key)
    authorized = []
    for path in args.authorized_key:
        authorized.extend(line.strip() for line in path.read_text().splitlines() if line.strip())
    seed = {
        "version": 1,
        "username": args.username,
        "hostname": args.hostname,
        "hostPrivateKey": key.read_text(),
        "hostPublicKey": recipient,
        "authorizedKeys": authorized,
        "accounts": encrypt_for_host(json.dumps(accounts).encode(), recipient),
    }
    for field, path in (
        ("tailscaleLive", args.tailscale_live_key),
        ("tailscaleTarget", args.tailscale_target_key),
    ):
        if path:
            seed[field] = encrypt_for_host(path.read_bytes(), recipient)
    from provisioning import validate_seed

    validate_seed(seed)
    (state / "identity.json").write_text(
        json.dumps(
            {k: seed[k] for k in ("username", "hostname", "hostPublicKey", "authorizedKeys")},
            indent=2,
        )
        + "\n"
    )
    return seed


def seal_seed(seed, state):
    bundle = state / f"{seed['hostname']}.age"
    temporary = state / f"{seed['hostname']}.age.new"
    temporary.unlink(missing_ok=True)
    print(
        "Choose a bundle passphrase. Enter it again on the stick to start personal setup.",
        flush=True,
    )
    try:
        run("age", "--passphrase", "--output", temporary, input=json.dumps(seed).encode())
        temporary.chmod(0o600)
        temporary.replace(bundle)
    finally:
        temporary.unlink(missing_ok=True)
    return bundle


def setup_volume(path):
    if path is None:
        if platform.system() != "Darwin":
            raise ValueError("Pass --volume with the mounted SETUP partition of the stick")
        path = Path("/Volumes/SETUP")
    if not (path / ".nixos-portable").is_file():
        raise ValueError(f"{path} is not the SETUP volume of a portable NixOS stick")
    return path


def copy_seed(bundle, volume):
    destination = volume / bundle.name
    temporary = volume / (bundle.name + ".new")
    shutil.copyfile(bundle, temporary)
    os.replace(temporary, destination)
    if platform.system() == "Darwin":
        run("sync")
    else:
        os.sync()
    return destination


def build_image(source, state, stick):
    link = state / "image"
    expression = (
        f'(builtins.getFlake "git+file://{source}").lib.mkStick'
        ' (builtins.fromJSON (builtins.getEnv "PORTABLE_STICK"))'
    )
    run(
        "nix",
        "build",
        "--impure",
        "--expr",
        f"({expression}).config.system.build.usbImage",
        "--out-link",
        link,
        env={**os.environ, "PORTABLE_STICK": json.dumps(stick)},
    )
    images = list(link.glob("*.raw.xz"))
    if len(images) != 1:
        raise ValueError("Expected exactly one disk image from the build")
    return images[0]


def inspect_usb(device, image_size):
    """Describe a whole, writable USB disk, the same way on macOS and Linux."""
    if platform.system() == "Darwin":
        info = plistlib.loads(subprocess.check_output(["diskutil", "info", "-plist", device]))
        suitable = (
            info.get("WholeDisk")
            and not info.get("Internal", True)
            and info.get("BusProtocol") == "USB"
            and info.get("Writable", False)
        )
        identifier = info.get("DeviceIdentifier")
        disk = {
            "id": identifier,
            "name": info.get("MediaName"),
            "size": info.get("TotalSize", 0),
            "raw": f"/dev/r{identifier}",
            "identity": [
                info.get(key)
                for key in ("DeviceIdentifier", "TotalSize", "MediaName", "DeviceTreePath")
            ],
        }
    else:
        listing = subprocess.check_output(
            [
                "lsblk",
                "--json",
                "--bytes",
                "--nodeps",
                "-o",
                "PATH,TYPE,TRAN,RO,SIZE,MODEL,SERIAL",
                device,
            ]
        )
        [info] = json.loads(listing)["blockdevices"]
        suitable = info["type"] == "disk" and info["tran"] == "usb" and not info["ro"]
        disk = {
            "id": Path(info["path"]).name,
            "name": info.get("model"),
            "size": info.get("size") or 0,
            "raw": info["path"],
            "identity": [info.get(key) for key in ("path", "size", "model", "serial")],
        }
    if not suitable or disk["size"] < image_size:
        raise ValueError("Select a writable external whole USB disk with enough space")
    return disk


def image_size(image):
    if image.suffix != ".xz":
        return image.stat().st_size
    listing = subprocess.check_output(["xz", "--robot", "--list", str(image)], text=True)
    totals = next(line.split("\t") for line in listing.splitlines() if line.startswith("totals"))
    return int(totals[4])


def unmount(disk):
    if platform.system() == "Darwin":
        run("diskutil", "unmountDisk", disk["raw"].replace("/dev/r", "/dev/"))
        return
    listing = subprocess.check_output(["lsblk", "--json", "-o", "PATH,MOUNTPOINTS", disk["raw"]])
    for device in json.loads(listing)["blockdevices"]:
        for child in device.get("children") or []:
            if any(child.get("mountpoints") or []):
                run("sudo", "umount", child["path"])


def write_usb(image, device):
    size = image_size(image)
    disk = inspect_usb(device, size)
    print(f"ERASE ALL DATA: {disk['id']}, {disk['name']}, {disk['size']} bytes")
    if input(f"Type ERASE {disk['id']} to write this USB: ") != f"ERASE {disk['id']}":
        raise ValueError("USB write cancelled")
    if inspect_usb(device, size)["identity"] != disk["identity"]:
        raise ValueError("USB identity changed; inspect devices again")
    unmount(disk)
    source = shlex.quote(str(image))
    read = f"xz -dc {source}" if image.suffix == ".xz" else f"cat {source}"
    raw = shlex.quote(disk["raw"])
    run("sh", "-c", f"{read} | sudo dd of={raw} bs=4194304")
    run("sync")
    # Compare only the written image length; the USB is usually larger.
    run("sh", "-c", f"{read} | sudo cmp -n {size} - {raw}")
    if platform.system() == "Darwin":
        run("diskutil", "eject", disk["raw"].replace("/dev/r", "/dev/"))
    print("USB write and byte-for-byte verification complete.")


def stick_parameters(args):
    stick = {}
    if args.user:
        stick["user"] = args.user
    if args.hostname:
        stick["hostname"] = args.hostname
    keys = [
        line.strip()
        for path in args.authorized_key
        for line in path.read_text().splitlines()
        if line.strip()
    ]
    if keys:
        stick["authorizedKeys"] = keys
    if args.persistent_tailscale:
        stick["persistentTailscale"] = True
    return stick


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    write = sub.add_parser("write", help="Erase a USB stick and write the portable image")
    write.add_argument("--image", type=Path, help="A built and verified portable image")
    write.add_argument("--source", type=Path, default=Path(__file__).resolve().parents[1])
    write.add_argument("--device", required=True, help="Confirmed external whole USB disk")
    stick = write.add_argument_group("building a stick (ignored with --image)")
    stick.add_argument("--user", help="Login of the stick's main user (default nixos)")
    stick.add_argument("--hostname", help="Hostname of the stick (default portable)")
    stick.add_argument("--authorized-key", type=Path, action="append", default=[])
    stick.add_argument(
        "--persistent-tailscale",
        action="store_true",
        help="Keep the stick's Tailscale login across reboots",
    )

    seed = sub.add_parser("seed", help="Add a personal setup bundle to a portable stick")
    seed.add_argument("--username", default="alex")
    seed.add_argument("--hostname", default="alex-nixos")
    seed.add_argument("--email", default="alexmalison@gmail.com")
    seed.add_argument("--volume", type=Path, help="Mounted SETUP volume (default /Volumes/SETUP)")
    seed.add_argument(
        "--stage-only",
        action="store_true",
        help="Prepare identity and encrypted accounts without sealing or copying a bundle",
    )
    seed.add_argument("--authorized-key", type=Path, action="append", default=[])
    seed.add_argument("--tailscale-live-key", type=Path)
    seed.add_argument("--tailscale-target-key", type=Path)
    args = parser.parse_args()
    os.umask(0o077)

    if args.command == "write":
        stick = stick_parameters(args)
        if args.image:
            if stick:
                parser.error("--image is already built; drop the stick options or --image")
            if not args.image.is_file():
                raise ValueError("The portable image does not exist")
            image = args.image.resolve()
        else:
            if args.user or args.hostname:
                validate_identity(args.user or "nixos", args.hostname or "portable", "other")
            state = Path.home() / ".local/state/nixos-portable"
            state.mkdir(parents=True, exist_ok=True, mode=0o700)
            image = build_image(args.source.resolve(), state, stick)
        write_usb(image, args.device)
        print("Plug the stick in again; its SETUP volume takes personal bundles.")
        return

    for executable in ("age", "ssh-keygen", "codex"):
        if not shutil.which(executable):
            raise ValueError(f"Missing {executable}; run through `just prepare` in the Nix shell")
    validate_identity(args.username, args.hostname, "other")
    volume = None if args.stage_only else setup_volume(args.volume)
    state = Path.home() / ".local/state/nixos-family-installer" / args.hostname
    state.mkdir(parents=True, exist_ok=True, mode=0o700)
    prepared = prepare_identity(args, state)
    if args.stage_only:
        print(f"Prepared public identity: {state / 'identity.json'}")
        return
    bundle = seal_seed(prepared, state)
    destination = copy_seed(bundle, volume)
    (state / "codex-login/auth.json").unlink()
    print(f"Personal bundle: {destination}\nPublic identity: {state / 'identity.json'}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, subprocess.CalledProcessError) as error:
        print(f"Preparation stopped: {error}", file=sys.stderr)
        sys.exit(1)
