"""Explicit, encrypted enrollment for personal installation media."""

import json
import os
from pathlib import Path
import signal
import subprocess
import time

from prepare_target import validate_identity


def private_write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if path.is_symlink():
        raise ValueError(f"Refusing a credential symlink: {path}")
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as stream:
        os.fchmod(stream.fileno(), 0o600)
        stream.write(data if isinstance(data, bytes) else data.encode())


def public_key(path):
    return subprocess.check_output(["ssh-keygen", "-y", "-f", str(path)], text=True).strip()


def encrypt_for_host(data, recipient):
    return subprocess.check_output(
        ["age", "--armor", "--encrypt", "--recipient", recipient], input=data
    ).decode()


def decrypt_for_host(ciphertext, key):
    return subprocess.check_output(
        ["age", "--decrypt", "--identity", str(key)], input=ciphertext.encode()
    )


def validate_seed(seed, username=None, hostname=None, owner="other"):
    if seed.get("version") != 1:
        raise ValueError("Unsupported personal media format")
    validate_identity(seed["username"], seed["hostname"], "other")
    if (
        owner != "other"
        or (username and username != seed["username"])
        or (hostname and hostname != seed["hostname"])
    ):
        raise ValueError(
            f"This personal USB is for Another person / {seed['username']} / {seed['hostname']}"
        )
    keys = seed["authorizedKeys"]
    if not isinstance(keys, list) or any(
        not isinstance(key, str) or not key.startswith("ssh-ed25519 ") or "\n" in key
        for key in keys
    ):
        raise ValueError("Support access must use explicit Ed25519 public keys")
    if not isinstance(seed["accounts"], str) or not seed["accounts"].startswith("-----BEGIN AGE"):
        raise ValueError("Missing encrypted agent accounts")


def read_seed(path):
    if not path.exists():
        return None
    if path.stat().st_size > 1024 * 1024:
        raise ValueError("Personal media bundle exceeds 1 MiB")
    seed = json.loads(path.read_text())
    validate_seed(seed)
    return seed


LIVE_STATE = Path("/run/family-installer")
# Owned by the live user, outside the root-only state directory.
SETUP_HOME = Path("/run/family-setup")


def load_live_seed(bundles=Path("/setup"), state=LIVE_STATE):
    seed = read_seed(state / "seed.json")
    if any(bundles.glob("*.age")) and (seed is None or not (state / "unlocked").exists()):
        raise ValueError(
            "Unlock a personal bundle with Start personal setup before installing, "
            "or move the bundles off the SETUP volume for a generic installation"
        )
    return seed


def install_identity(seed, key):
    if key.exists():
        if public_key(key) != seed["hostPublicKey"]:
            raise ValueError("Existing target host key differs from the prepared identity")
    else:
        private_write(key, seed["hostPrivateKey"])
        if public_key(key) != seed["hostPublicKey"]:
            key.unlink()
            raise ValueError("Prepared host key does not match its public key")
    key.chmod(0o600)
    key.with_suffix(".pub").write_text(seed["hostPublicKey"] + "\n")


def install_accounts(accounts, home, uid, gid):
    for name, relative in (("codex", ".codex/auth.json"), ("claude", ".claude/.credentials.json")):
        if name not in accounts:
            continue
        path = home / relative
        # Preserve refreshed credentials across boots and installation retries.
        if not path.exists():
            private_write(path, json.dumps(accounts[name]))
            os.chown(path, uid, gid)
            os.chown(path.parent, uid, gid)
    if "claude" in accounts and not (home / ".claude.json").exists():
        path = home / ".claude.json"
        private_write(path, json.dumps({"hasCompletedOnboarding": True}))
        os.chown(path, uid, gid)


def provision_target(seed, root, machine):
    validate_seed(seed)
    key = root / "etc/ssh/ssh_host_ed25519_key"
    install_identity(seed, key)
    state = root / "var/lib/family-installer"
    state.mkdir(parents=True, exist_ok=True, mode=0o700)
    if not (state / "accounts-handed-off").exists():
        private_write(state / "accounts.age", seed["accounts"])
    if seed.get("tailscaleTarget"):
        private_write(state / "tailscale.age", seed["tailscaleTarget"])
    (machine / "provisioning.json").write_text(
        json.dumps(
            {
                "username": seed["username"],
                "authorizedKeys": seed["authorizedKeys"],
                "tailscale": bool(seed.get("tailscaleTarget")),
            },
            indent=2,
        )
        + "\n"
    )
    (machine / "provisioning.nix").write_text(
        "{...}: let\n  seed = builtins.fromJSON (builtins.readFile ./provisioning.json);\n"
        "in {\n  imports = [../../modules/provisioned-system.nix];\n"
        "  familyInstaller.provisioning = {\n"
        "    enable = true;\n    inherit (seed) authorizedKeys tailscale;\n  };\n}\n"
    )


def refresh_target_accounts(root, seed, home=SETUP_HOME):
    root = root.resolve()
    if root == Path("/") or not (root / "srv/nixos-family-installer/.installer-source").is_file():
        raise ValueError("The target has not been prepared by this installer")
    key = root / "etc/ssh/ssh_host_ed25519_key"
    if public_key(key) != seed["hostPublicKey"]:
        raise ValueError("Target identity changed before account handoff")
    selected = json.loads(decrypt_for_host(seed["accounts"], key))
    state = root / "var/lib/family-installer"
    marker = state / "accounts-handed-off"
    accounts = {}
    paths = []
    for name, relative in (("codex", ".codex/auth.json"), ("claude", ".claude/.credentials.json")):
        if name in selected:
            path = home / relative
            paths.append(path)
            if marker.exists():
                continue
            if not path.is_file():
                raise ValueError(f"The live {name} account was removed; sign in before finishing")
            accounts[name] = json.loads(path.read_text())
    if not marker.exists():
        private_write(
            state / "accounts.age",
            encrypt_for_host(json.dumps(accounts).encode(), seed["hostPublicKey"]),
        )
        private_write(marker, "complete\n")
    for path in paths:
        path.unlink(missing_ok=True)


def live_codex_pids(home, proc=Path("/proc")):
    marker = b"HOME=" + str(home).encode()
    pids = []
    for entry in proc.iterdir():
        if not entry.name.isdigit():
            continue
        try:
            name = (entry / "comm").read_text().strip()
            environment = (entry / "environ").read_bytes().split(b"\0")
        except OSError:
            continue
        if name in {"codex", ".codex-wrapped"} and marker in environment:
            pids.append(int(entry.name))
    return pids


def stop_live_codex(home=SETUP_HOME):
    """Stop only the setup session's agents, not other Codex sessions on the stick."""
    for pid in live_codex_pids(home):
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    for _ in range(50):
        if not live_codex_pids(home):
            return
        time.sleep(0.1)
    raise ValueError("Close the live Codex sessions before finishing account transfer")


def tailscale_running():
    result = subprocess.run(
        ["tailscale", "status", "--json"], capture_output=True, text=True, check=False
    )
    try:
        return json.loads(result.stdout).get("BackendState") == "Running"
    except ValueError:
        return False


def boot_target(
    username,
    state=Path("/var/lib/family-installer"),
    key=Path("/etc/ssh/ssh_host_ed25519_key"),
    runtime=Path("/run/family-installer"),
):
    import pwd

    user = pwd.getpwnam(username)
    encrypted = state / "accounts.age"
    if encrypted.exists():
        accounts = json.loads(decrypt_for_host(encrypted.read_text(), key))
        install_accounts(accounts, Path(user.pw_dir), user.pw_uid, user.pw_gid)
        encrypted.unlink()
    if (state / "tailscale.age").exists():
        private_write(
            runtime / "tailscale-authkey",
            decrypt_for_host((state / "tailscale.age").read_text(), key),
        )


def unlock_live(
    bundle,
    username,
    state=LIVE_STATE,
    ready=Path("/run/family-installer.ready"),
    home=SETUP_HOME,
):
    import pwd

    result = subprocess.check_output(["age", "--decrypt", str(bundle)])
    seed = json.loads(result)
    validate_seed(seed)
    previous = read_seed(state / "seed.json")
    if previous and previous["hostname"] != seed["hostname"]:
        raise ValueError(f"This session is already set up for {previous['hostname']}; reboot first")
    key = state / "target-host-key"
    install_identity(seed, key)
    accounts = json.loads(decrypt_for_host(seed["accounts"], key))
    user = pwd.getpwnam(username)
    # The setup session gets its own home, so the stick user's logins are never
    # handed to the installed computer.
    home.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chown(home, user.pw_uid, user.pw_gid)
    install_accounts(accounts, home, user.pw_uid, user.pw_gid)
    private_write(state / "seed.json", result)
    if seed["authorizedKeys"]:
        authorized = state / "authorized_keys" / username
        authorized.parent.mkdir(parents=True, exist_ok=True)
        authorized.parent.chmod(0o755)
        private_write(authorized, "\n".join(seed["authorizedKeys"]) + "\n")
        authorized.chmod(0o644)
    if seed.get("tailscaleLive") and tailscale_running():
        print("Tailscale is already connected on this stick; keeping its existing login.")
    elif seed.get("tailscaleLive"):
        auth = state / "tailscale-live-authkey"
        private_write(auth, decrypt_for_host(seed["tailscaleLive"], key))
        try:
            subprocess.run(
                [
                    "tailscale",
                    "up",
                    f"--auth-key=file:{auth}",
                    "--hostname",
                    seed["hostname"] + "-installer",
                ],
                check=True,
            )
        finally:
            auth.unlink()
    private_write(state / "unlocked", "ready\n")
    ready.write_text(seed["hostname"] + "\n")
    print(f"Personal setup ready: Another person / {seed['username']} / {seed['hostname']}")


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    boot = sub.add_parser("boot")
    boot.add_argument("username")
    unlock = sub.add_parser("unlock")
    unlock.add_argument("bundle", type=Path)
    unlock.add_argument("username")
    args = parser.parse_args()
    if args.command == "boot":
        boot_target(args.username)
    else:
        unlock_live(args.bundle, args.username)
