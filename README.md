# Portable NixOS USB and family installer

A writable NixOS installation on a USB stick that you can carry around. It
works as a rescue system, as a NixOS you can keep using, and as a graphical
installer for family computers. You write the generic stick once. For each
computer, preparation adds an encrypted personal bundle to the stick's `SETUP`
volume. That bundle holds the new owner's agent account, a newly generated host
key, and any helper access you selected. Calamares then installs NixOS with
T3 Code and that account.

The generic stick contains no credentials. Ivan's own stick is this same module
plus a personal layer in
[dotfiles](https://github.com/colonelpanic8/dotfiles)
(`nixos/machines/rescue-usb.nix`): his account, Hyprland, Tailscale enrollment,
and desktop agent apps.

This is the operating guide for the person installing, a remote helper, and an
assisting agent. Start at the section matching the current state. Commands in
an installed-system section run on the new family computer, not Ivan's workstation.

- [What is on the stick](#what-is-on-the-stick)
- [Make a stick for someone](#make-a-stick-for-someone)
- [Prepare a stick on Alex's Mac](#prepare-a-stick-on-alexs-mac)
- [Build the image](#build-the-image)
- [Write the image from Windows or Linux](#write-the-image-from-windows-or-linux)
- [Boot the stick](#boot-the-stick)
- [Connect a remote helper](#connect-a-remote-helper)
- [Install through Calamares](#install-through-calamares)
- [Replace an existing installation](#replace-an-existing-installation)
- [Check the installed computer](#check-the-installed-computer)
- [Register the machine](#register-the-machine)
- [Enable conservative updates](#enable-conservative-updates)
- [Grant persistent support access or secrets](#grant-persistent-support-access-or-secrets)
- [Troubleshoot and recover](#troubleshoot-and-recover)
- [Instructions for an assisting agent](#instructions-for-an-assisting-agent)
- [Maintain the installer](#maintain-the-installer)
- [Implementation reference](#implementation-reference)

## What is on the stick

| Partition | Label (GPT partition label for the ESP) | Contents |
| --- | --- | --- |
| EFI system (1 GiB) | `PORTABLE-ESP` | systemd-boot, NixOS generations, memtest86+ |
| FAT data (256 MiB) | `SETUP` | Personal bundles (`*.age`). Mounted at `/setup` on the stick; macOS and Windows mount it automatically |
| ext4 root | `PORTABLE-ROOT` | The NixOS installation. It grows to fill the stick on first boot |

The generic stick logs in to Plasma automatically as its main user (`nixos`
unless built for someone; see below), with an empty password and passwordless
`sudo`. It includes Calamares (**Install System**),
**Start personal setup**, T3 Code, Codex, Claude Code, Tailscale, Firefox,
GParted, and a disk, filesystem, and hardware rescue kit. Its state persists
across reboots, except Tailscale, which keeps its state in memory: every boot
starts unenrolled. SSH listens only on `tailscale0`.

The first boot registers the Nix store, creates the system profile, and installs
systemd-boot. After that the stick is an ordinary NixOS system. Update it with
`portable-update`, which rebuilds the latest release of this repository with
the parameters the stick was built with (recorded in
`/etc/nixos-portable/stick.json`). Update Ivan's stick with `just switch` from
`/srv/dotfiles/nixos` instead.

**Start personal setup** lists the bundles on `SETUP` and asks for the
passphrase of the one you choose. It then installs that bundle's accounts into
a separate, in-memory home (`/run/family-setup`) and opens T3 Code
there. The stick's own logins and files therefore never reach the installed
computer. The unlocked session ends at reboot. While a bundle is on `SETUP`,
Calamares refuses to install until one is unlocked. For a generic installation,
move the bundles off the `SETUP` volume.

## Make a stick for someone

A stick for someone else, such as Ivan's dad, is this repository's stick built
with their login. It carries nothing from Ivan's dotfiles: no credentials, no
Hyprland, and no agenix secrets. On x86_64 Linux, from a checkout:

```sh
nix develop --command just prepare write \
  --user dad --hostname dad-stick \
  --authorized-key ~/.ssh/id_ed25519.pub \
  --device /dev/disk/by-id/usb-REPLACE_WITH_CONFIRMED_DEVICE
```

This builds the image for those parameters and then writes it with the
`ERASE` confirmation described below. On Linux, it unmounts the stick's
mounted partitions first. Options:

| Option | Default | Effect |
| --- | --- | --- |
| `--user` | `nixos` | Login of the stick's main user, which logs in automatically |
| `--hostname` | `portable` | Hostname, including the stick's Tailscale name |
| `--authorized-key` | none | Public keys (files) allowed to SSH in as that user over Tailscale; repeatable |
| `--persistent-tailscale` | off | Keep the stick's Tailscale login across reboots, for ongoing remote help |

These are ordinary build parameters: everything they put on the stick is
public. Keep credentials off the stick. An agent login for a computer
the stick installs travels in a personal bundle (next section). From Nix, the
same stick is
`nixos-portable.lib.mkStick { user = "dad"; hostname = "dad-stick"; }`.

## Prepare a stick on Alex's Mac

Use the MacBook Air already on Tailscale, logged in as `alex`, with a checkout
of this repository. This Mac prepares the stick; NixOS goes on the separate
x86_64 PC. The Mac's internal disk is never an installation destination. Read
[START-HERE.md](START-HERE.md) for the short walkthrough and a prompt for the
assisting agent.

### 1. Write the portable image (once per stick)

Skip this step if the stick already has the portable image. In that case its
`SETUP` volume appears in Finder. Otherwise get a verified image built from this
repository (see [Build the image](#build-the-image)). A helper can build it on
Linux and copy it over with SCP. Compare SHA-256 at both ends. Then plug in the
stick and inspect:

```sh
diskutil list external physical
```

Match model and capacity, back up any needed files on the stick, then write.
Replace `/dev/diskN` with the actual external whole USB disk:

```sh
just prepare write --image /Users/alex/Downloads/nixos-portable.raw.xz --device /dev/diskN
```

**This erases every file and partition on that USB.** The writer rejects
internal disks, partitions, non-USB devices, read-only media, and undersized
devices. It displays the selected disk and requires typing `ERASE diskN`
before writing. It rechecks the disk's identity, writes the image, verifies
the bytes, and ejects the stick. Without `--image`, it builds the image from
this checkout. That requires x86_64 Linux or a configured Linux builder; Apple
Silicon macOS alone cannot build x86_64 Linux images.

### 2. Add a personal bundle (once per computer)

Plug the stick in again so that `/Volumes/SETUP` appears, then run:

```sh
just prepare seed --authorized-key /Users/alex/.ssh/id_ed25519.pub
```

Defaults are login `alex`, hostname `alex-nixos`, account email
`alexmalison@gmail.com`, and **Another person**. To prepare another person's
computer, override them with `--username`, `--hostname`, and `--email`. Use
`--volume` when the `SETUP` volume is mounted somewhere else. The command opens
a **separate Codex login for the new PC**. It uses
`~/.local/state/nixos-family-installer/<hostname>/codex-login` as `CODEX_HOME`.
Sign in as `alexmalison@gmail.com` in the browser when prompted. The command
checks that email before exporting. It never exports the Mac's usual
`~/.codex/auth.json`: sharing a refresh token between independent computers
can invalidate their sessions. After it has copied the bundle to the stick, it
removes the temporary login file from the preparation profile. It does not
copy conversations, settings, Git-sync directories, or GPG material. Claude
Code is installed but its account is not exported; sign in separately later
if wanted.

The command keeps the prepared host identity under
`~/.local/state/nixos-family-installer/<hostname>/` and reuses it on retries.
Only `identity.json` and the `.pub` file are public. The private host key stays
on this trusted preparation Mac and travels in the encrypted bundle. Inside the
bundle, account credentials are additionally encrypted to the host key. Choose
a bundle passphrase when prompted; you enter it again on the stick. It protects
the credentials if the stick is lost, and it is separate from the eventual
disk-unlock and login passwords. Keep private media out of cloud sharing and
source control.

The bundle is written to `SETUP/<hostname>.age`. One stick can carry bundles
for several computers. Eject the stick in Finder before unplugging it.

### 3. Install

Boot the separate PC from the stick. Connect its network. On the generic stick,
**Start personal setup** opens automatically while a bundle is present. Choose
the bundle and enter its passphrase; T3 Code then opens. Open the `Setup`
project and use the prompt in `START-HERE.md`. Choose Codex. Calamares refuses
to partition while a bundle is still locked, and it validates the prepared
user, hostname, and owner. Its disk, bootloader, encryption, and password
screens remain in charge of the installation. The person must separately
confirm the actual internal disk.

At the end of installation, Calamares stops the setup session's Codex
processes. Codex sessions belonging to the stick's own user are left alone.
It then encrypts the setup session's current credentials for the target,
including token refreshes during setup, and removes the live login. The live
agent disconnecting at this point is expected. Reboot when Calamares finishes,
and continue with the agent on the installed system. The installed computer
receives T3 Code and those credentials at first boot, then deletes its
encrypted account bootstrap file. Later logouts or account changes are kept.

A bundle is a **single-install credential transfer**. Booting its original
credential snapshot again may require a fresh login. After a successful
install, delete `SETUP/<hostname>.age` and the Mac's copy under
`~/.local/state/nixos-family-installer/<hostname>/` when you no longer need
them. Keep the public identity record for support. Credentials remain
revocable and may expire or require a later provider login; preparation is not
a promise of permanent authentication. The setup session's home is in memory,
so save needed notes to the target before rebooting.

### Optional pre-authorized remote support

Pass each approved helper's Ed25519 **public** key with `--authorized-key`.
Never pass a private helper key. While the bundle is unlocked, the stick
accepts those keys for its live user through `/run/family-installer`. Nothing
is written to the stick's home. Prepared targets accept key-based SSH on
`tailscale0`, disable password and root SSH, and do not open SSH to the LAN.

To avoid a Tailscale login at installation, arrange two distinct
pre-authorized, appropriately scoped, single-use enrollment keys ahead of
time: one for the live stick and one for the permanent PC. Pass their paths
with `--tailscale-live-key` and `--tailscale-target-key`. The command encrypts
each one to the new host key; neither is a Nix input. The live node uses
`<hostname>-installer`. A stick that is already connected to Tailscale (Ivan's,
for example) keeps its existing login and ignores the live key. The target
enrolls independently at first boot. Its encrypted enrollment key and runtime
plaintext are removed after Tailscale reports Running. If enrollment fails,
the encrypted key remains for retry; replace an expired key, or remove that
bootstrap file before retrying with an interactive login. Do not copy the
Mac's Tailscale state or reuse its device identity. A tag or auth key alone
does not restrict access: verify that the tailnet's policy permits only the
intended helper access and does not give the family device broad access to
Ivan's machines.

Without these keys, Tailscale is available but not pre-authenticated. Codex
assistance and installation still work locally. Neither `--authorized-key`
nor a running Tailscale daemon implies that remote enrollment is complete.
Only report support as ready after actually testing the intended connection.

## Build the image

Build on x86_64 Linux with Nix and flakes:

```sh
git clone https://github.com/colonelpanic8/nixos-portable.git
cd nixos-portable
nix develop --command just check
nix flake check
nix build .#usb-image
```

With direnv, run `direnv allow` after reviewing `.envrc`, then use
`direnv exec . just check` and `direnv exec . just build` instead. The
xz-compressed raw image appears under `result/`. Most of its root filesystem
is free space that compresses away; uncompressed, it needs a stick of at least
32 GB. Record its checksum and the commit so a helper
can identify the exact media:

```sh
git rev-parse HEAD
sha256sum result/*.raw.xz
```

You can also build from GitHub without a checkout:
`nix build github:colonelpanic8/nixos-portable#usb-image`. Ivan's personal
image comes from dotfiles: `just rescue-usb-image` in `/srv/dotfiles/nixos`.

To exercise the image without a physical stick, run
`nix develop --command just vm`. It boots a disposable copy of the image under
UEFI as a USB device, with a blank 40 GiB virtual disk to install onto, and
prints the directory holding those files. Remove that directory after shutting
down the VM.

`master` is the development branch. `family-stable` is the manually promoted
release that installed family computers follow. Building or writing a stick
does not need that branch. This repository has its own Nixpkgs and Home
Manager lockfile; building it does not evaluate the dotfiles workstation flake
or fetch its private inputs.

## Write the image from Windows or Linux

**Writing the image erases every file and partition on the selected USB.**
Back up its files. Unplug other removable drives to reduce selection mistakes.
Use a stick of at least 32 GB.

On Windows, verify the file with
`Get-FileHash -Algorithm SHA256 -LiteralPath 'C:\path\to\nixos-portable.raw.xz'`
and compare all 64 hexadecimal digits with the helper's checksum. Then use
[balenaEtcher](https://etcher.balena.io/): **Flash from file**, select the
verified `.raw.xz` image (Etcher decompresses it), **Select target**, match the stick's model and capacity,
and **Flash**. Let both writing and validation finish. If Windows offers to
format the stick afterwards, cancel. After writing, Windows mounts the `SETUP`
volume, which can take a bundle prepared elsewhere.

On Linux, `just prepare write --image <file> --device <disk>` checks that
the device is a whole, writable USB disk, asks for the `ERASE` confirmation,
then writes and verifies it. To write by hand instead, inspect the available
devices before selecting the stick:

```sh
lsblk -p -o NAME,SIZE,MODEL,TRAN,FSTYPE,MOUNTPOINTS
ls -l /dev/disk/by-id/usb-*
```

Match the stick by model and capacity, and unmount its mounted partitions. The
output device must be the whole USB device, not a partition such as
`/dev/sdb1` or a by-id name ending in `-part1`. An agent must have
confirmation of the actual destination device before running the write:

```sh
IMAGE=/absolute/path/to/nixos-portable.raw.xz
USB_DEVICE=/dev/disk/by-id/usb-REPLACE_WITH_CONFIRMED_DEVICE
test -f "$IMAGE" && test -b "$USB_DEVICE"
lsblk -p -o NAME,SIZE,MODEL,TRAN,MOUNTPOINTS "$USB_DEVICE"
xz -dc "$IMAGE" | sudo dd of="$USB_DEVICE" bs=4M conv=fsync status=progress
sync
```

If the file or device check fails, stop and correct the paths before running
`dd`. Do not substitute a guessed `/dev/sdX` name. On Linux, add a bundle with
`just prepare seed --volume <mounted SETUP path>`.

Do not overwrite Ivan's own stick unless he intends to replace it. It holds
his persistent home and Tailscale state.

## Boot the stick

Restart the destination computer and select the stick's UEFI entry in its
firmware boot menu. The stick is UEFI-only. If Secure Boot rejects it, record
the existing firmware setting before disabling Secure Boot for this unsigned
media. Confirm any disk-recovery requirements of the existing OS before
changing its firmware settings.

The generic stick reaches a Plasma desktop. Open **Install System** from the
application menu or the desktop. Ivan's stick reaches Hyprland: open the
application launcher with Super+P and choose **Install System** or **Start
personal setup**, or run `family-installer` from Ghostty (Super+Shift+Return).
The boot menu also offers memtest86+; Ivan's stick additionally offers
PassMark MemTest86.

## Connect a remote helper

Someone at the computer must connect Wi-Fi or Ethernet and complete any login
shown by Tailscale. With a bundle that included helper keys and a live
Tailscale key, this is already done once **Start personal setup** has
unlocked it. Otherwise, on the generic stick, open Konsole and run:

```sh
sudo tailscale up
sudo passwd nixos
tailscale ip -4
```

Set a temporary password for the live `nixos` account. Share it privately with
the helper, along with the printed Tailscale address. Do not put passwords or
authentication links in a public issue, PR, or transcript. On the generic
stick, the password persists until changed. Tailscale enrollment does not
survive a reboot.

On Ivan's stick, the live user is `imalison`, Tailscale is normally already
enrolled, and Ivan's SSH public keys are authorized. Inspect
`tailscale status` before changing anything; avoid replacing its tailnet
identity or account password without Ivan's agreement.

Ivan approves the device and limits its access in the tailnet's policy.
Merely joining a tailnet does not prove that the intended access restrictions
exist. The generic image contains no Tailscale enrollment key.

From an authorized helper machine, connect with the actual live username:

```sh
ssh nixos@100.x.y.z
```

Check the live host's fingerprint through the person at the computer before
accepting a new SSH identity. The stick and the installed computer have
separate identities. A changed fingerprint after reboot requires verification.

SSH provides a shell. Graphical screen sharing is not configured. The person
at the computer clicks through Calamares while the helper explains choices
and reads relevant diagnostics. An agent on a generic stick needs its own
login. A personal bundle explicitly supplies the accounts selected during
preparation.

Keep a way to contact the person outside this SSH session. Installation and
reboot end the live session. Generic installations do not inherit the live
Tailscale or agent login. A personal bundle provisions the target separately;
temporary live passwords and live Tailscale state are still not copied.

## Install through Calamares

1. Choose the language, location, and keyboard layout. Confirm the keyboard
   before entering passwords, particularly when it differs from US English.
2. On **Primary user**, select **Another person** for Dad. Select **Ivan** only
   when Ivan's Git name and email are wanted. This choice grants no secrets.
3. On **Users**, enter the person's full name, a lowercase login name, and a
   unique computer name. For example, use login `dad` and computer `dad-laptop`.
   The login name can differ from `imalison` even when choosing Ivan.
4. Enter the account password and administrator password. Calamares offers a
   checkbox to use the same password for both. Keep these passwords private.
5. Select a desktop. Plasma is the desktop tested end to end with this installer.
6. Decide whether the hardware needs unfree software. Some graphics and network
   hardware require it. The choice affects the generated target configuration.
7. On **Partitions**, identify the destination by model and capacity. Exclude
   the boot USB and every disk containing data that must be preserved.
8. Use **Erase disk** only when replacing all contents of that destination is
   intended. Existing dual-boot layouts and manual partitioning need individual
   review. This project has not verified every layout offered by Calamares.
9. If selecting **Encrypt system**, record the disk-unlock passphrase privately.
   It is separate from the account password. The tested UEFI layout uses a
   FAT32 boot partition and a LUKS2-encrypted root filesystem.
10. Review **Summary** with the person at the computer. Confirm the destination,
    deletion, partition layout, and encryption before clicking **Install**.
    The stock configuration does not show another confirmation dialog.
11. Wait for **All done**. If installation fails, collect diagnostics before
    rebooting. An error after partitioning may leave the disk partially installed.
12. Select **Restart now**, finish, and boot the internal disk. Remove the USB
    when it is safe to do so, or select the internal disk in the firmware menu.

A computer name must be at most 63 characters, start and end with a letter or
digit, and contain only letters, digits, underscores, or hyphens. Avoid
underscores for compatibility with other network tools. `localhost` and
`installer` are reserved. Login names are lowercase, at most 31 characters,
and cannot be `root` or `nobody`.

At boot, enter the disk passphrase if encryption is enabled. Then sign in with
the account password. SSH cannot unlock the encrypted disk before boot; this
project does not configure remote unlocking in the initrd.

## Replace an existing installation

For a computer whose existing OS and files can all be discarded, use
Calamares' **Erase disk** option on the confirmed internal destination disk.
This replaces the entire installation. It does not preserve the previous OS,
recovery partitions, applications, or personal files on that disk.

1. Before booting the installer, finish backups to another disk or a remote
   location. Disconnect any backup disk before partitioning.
2. Boot the USB in UEFI mode if the destination computer supports UEFI. Use
   **Another person**, the intended primary login, a unique hostname, and
   **Plasma**. Connect the helper before starting the installation.
3. On **Partitions**, select the internal destination by model and capacity.
   The installer USB is a separate device and must remain excluded. If there
   are multiple internal disks, identify the one whose contents may be removed.
4. Have the person confirm that this exact disk may be erased in full and
   that needed files are backed up. Then choose **Erase disk**. Do not choose
   install alongside, replace one partition, or manual partitioning for this
   whole-disk replacement. Let Calamares generate the partition layout.
5. If offered a filesystem choice, ext4 is suitable for this setup. Under UEFI,
   the generated plan must include an EFI System Partition mounted at
   `/boot` and a root filesystem mounted at `/`. An encrypted installation
   places the root filesystem inside LUKS; the EFI partition stays unencrypted.
   Use the installer's automatic sizes rather than entering device names or
   a partition table copied from another computer. Swap choices can use the
   installer defaults; hibernation is not required for this setup.
6. Decide on **Encrypt system** with the person. If enabled, they must retain
   the separate disk passphrase and enter it locally after every reboot.
   Remote SSH cannot unlock it. Do not choose or disclose the passphrase for them.
7. Review **Summary** together. Check the internal disk model and capacity,
   the full-disk deletion, the boot mode, and the proposed EFI and root mounts.
   If the USB, another disk, or an unexpected layout is listed for deletion,
   stop and correct the selection. **Install** starts disk writes without
   another confirmation dialog.
8. After installation completes, restart from the internal disk, remove the
   USB when safe, unlock the disk if encrypted, and sign in to the new account.
   Verify this boot before registering the machine or enabling managed updates.

The plan to replace the old installation does not identify a device by itself.
An assisting agent still needs the person's confirmation of the actual disk.
Booting the installer or confirming the USB is not confirmation to erase the
internal disk. On legacy BIOS hardware, the automatic bootloader layout is
different; have the helper review it instead of forcing the UEFI layout above.

## Check the installed computer

Run these commands in a terminal on the newly installed computer:

```sh
whoami
hostname
findmnt -n -o SOURCE,FSTYPE /
readlink -f /etc/nixos
nix eval --expr '1 + 1'
command -v zsh tmux zellij git
```

Expect the chosen login and computer name, the internal root filesystem,
`/srv/nixos-family-installer` as the configuration path, and `2` from Nix.
An encrypted root normally appears under `/dev/mapper/`.

Both owner choices receive flakes, Zsh, tmux, Zellij, shared multiplexer aliases,
and Git. Ivan receives his Git name and email. Another person receives no
inherited Git identity. Check the latter with `git config --get user.email`;
an unset value produces no output and a nonzero exit status.

The installer imports no personal GPG keys, password store, Git-sync repositories,
or Syncthing folders. Agent credentials are included only through explicit
personal media preparation. It does not create Ivan's account
in addition to the chosen primary account. The profile is a shared subset of
dotfiles, not the full workstation configuration or a symlink to Ivan's home.

Inspect the public enrollment request and host-key fingerprint:

```sh
cat /var/lib/nixos-family-installer/enrollment.json
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
stat -c '%a %U %n' /etc/ssh/ssh_host_ed25519_key
```

The request names the chosen machine and user, includes its public host key,
and requests no secrets. The private host-key file belongs to root with mode
`600`. Never print the private key or transfer it outside the documented trusted
Mac → encrypted personal media → target path.

Automatic updates are initially disabled. An absent `nixos-upgrade.timer` is
expected until registration. Installation can succeed without tailnet access,
secret approval, or an upstream PR.

## Register the machine

Do this from Ivan's trusted workstation after verifying the new computer's
public host-key fingerprint through the support session. Obtain these files
through an authorized connection or a reviewed removable-media transfer:

- `/srv/nixos-family-installer/machines/<hostname>/`, including `default.nix`,
  `identity.json`, `configuration.nix`, and `hardware-configuration.nix`.
- `/var/lib/nixos-family-installer/enrollment.json`.

The initial remote live session ends at reboot. If persistent SSH was not
configured, ask the person at the machine to assist with the transfer. Do not
assume that the pre-installation Tailscale address still reaches the computer.

Copy the machine directory into `machines/<hostname>/` in a checkout of this
repository (Ivan's is `~/projects/nixos-portable`). Keep it as an independent
machine definition; do not import the stick's configuration or Ivan's
workstation modules.
Inspect every file for accidental private data before committing or opening a
public PR. Generated filesystem UUIDs and hardware details also become public
when committed here. The public enrollment request is for review; it is not a
credential and does not authorize any grant.

On the workstation, replace `dad-laptop` below with the real hostname:

```sh
cd ~/projects/nixos-portable
git switch -c register-dad-laptop
git add machines/dad-laptop
nix develop --command just check
nix build .#nixosConfigurations.dad-laptop.config.system.build.toplevel
```

A Git-backed Nix flake sees new files only after they are added to Git. Review
the configuration and build result before publishing the branch or creating
a PR. GitHub authentication stays on the trusted workstation. The installer
does not open PRs or re-encrypt secrets automatically.

## Enable conservative updates

Register and verify the machine with updates disabled first. Once its definition
exists on the published `family-stable` branch, add this option to that machine's
module and build the change:

```nix
familyInstaller.updates.enable = true;
```

Review and publish that change through `family-stable` before activating it on
the family computer. On that computer, use its real hostname in the quoted URL:

```sh
sudo nixos-rebuild switch --flake 'github:colonelpanic8/nixos-portable/family-stable#dad-laptop'
systemctl status nixos-upgrade.timer
systemctl list-timers nixos-upgrade.timer
```

This activation command is for the family computer. Ivan's workstations and
his own stick rebuild with `just switch` from their primary
`/srv/dotfiles/nixos` checkout.

Updates run daily with up to 45 minutes of randomized delay. They use the
release's lockfile, retain boot entries, and do not reboot automatically. An
update may still restart services. `family-stable` is a manually maintained
branch, not an automatic test or approval gate. Its maintainers must build
and verify changes before promoting it.

Keep local edits in `/etc/nixos` under review. A successful remote update does
not rewrite that editable directory, so it may describe an older configuration
than `/run/current-system`. Use the published release URL for managed rebuilds
and carry desired local changes back into the registered machine definition.
Do not change `system.stateVersion` merely to match a newer NixOS release.

To stop managed updates on a registered computer, set
`familyInstaller.updates.enable = false;` in its machine module, build, and
activate that configuration. For an immediate temporary pause on the family
computer, stop the timer with `sudo systemctl stop nixos-upgrade.timer`; a
reboot or later activation can start it again.

## Grant persistent support access or secrets

Persistent support is an explicit change to the installed machine. For a
reviewed Tailscale and SSH setup, its machine module can contain:

```nix
services.tailscale.enable = true;
services.openssh.enable = true;
users.users.dad.openssh.authorizedKeys.keys = [
	"ssh-ed25519 REPLACE_WITH_APPROVED_HELPER_PUBLIC_KEY"
];
```

Replace the account name and key before building. Decide which network
interfaces may reach SSH and apply the intended Tailscale policy. This example
enables an SSH server; it is not a complete access policy. After activating the
configuration, enroll with `sudo tailscale up` on the installed computer and
verify that only the intended helper can connect.

The generated Ed25519 identity is an SSH **host** key, not the primary user's
SSH key and not Ivan's GPG key. Retry during preparation preserves it. An
approved agenix recipient can use this public key, but the safe shared profile
does not import agenix or any encrypted secret by default.

For each proposed secret, review its purpose and grant only that secret to
this host. Do not add a family machine to dotfiles' broad `hostKeys`,
`sshClientKeys`, or `agenixKeys` groups. Never copy Ivan's private GPG key,
password store, agent credentials, or Git-sync directories to satisfy an
installation or authentication failure. Choosing **Ivan** does not grant them.

## Troubleshoot and recover

### The USB does not boot

Check that the writer used raw image mode, selected the intended whole device,
and finished syncing. Compare the image checksum with the recorded build
checksum. The stick boots only in UEFI mode; inspect the firmware's USB, UEFI,
and Secure Boot choices. If possible, try the image with `just vm` before
rewriting a stick or changing more firmware settings.

If the stick boots once but not after its first boot, the systemd-boot install
may have failed. Choose the remaining entry, then inspect
`journalctl -u portable-install-bootloader`.

### Wi-Fi or remote access fails

Use the desktop network applet or `nmtui`. A wired connection can avoid an
unsupported Wi-Fi device during installation. Inspect `ip address`,
`tailscale status`, and `systemctl status tailscaled sshd`. Check the actual
live account, network access, device approval, and tailnet policy. Do not
resolve a connection failure by granting the machine broad secret access.

### Calamares reports an error

Launch through **Install System** or `family-installer`. The launcher uses the
privileged wrapper and permits the local root user to display the installer
on Xwayland. Running the bare `calamares` binary as an ordinary user cannot
complete privileged disk operations.

Keep the live environment running. Use **Toggle log** and inspect the session
log. In the tested installer, the privileged session log was at
`/root/.cache/calamares/session.log`; another launch context may place it under
`~/.cache/calamares/session.log` instead.

```sh
sudo tail -n 100 /root/.cache/calamares/session.log
lsblk -f
findmnt
```

Record the failed job, exact error, image commit, selected disk, firmware mode,
and whether partitioning already ran. Review and redact logs before sharing;
logs can contain usernames, hardware details, and other sensitive information.
The stick's filesystem persists, but the setup session's home and
`/run/family-installer` do not. Save diagnostics before rebooting.

The helper rejects invalid identities before partitioning. If validation fails,
correct the user or computer name. If preparation says an existing checkout
cannot be overwritten, inspect it before making any change. Never delete a
configuration directory just to bypass that protection.

### Installation finished but boot or login fails

Confirm the firmware is booting the internal disk. Distinguish the disk-unlock
passphrase from the account password and confirm the keyboard layout. A remote
helper cannot reach the normal SSH server while the computer waits for disk
unlock. If an update fails to boot, select a retained earlier NixOS generation
from the boot menu.

To inspect a damaged installation, boot the stick again, identify its partitions
with `lsblk -f`, and unlock the correct LUKS volume if needed. Mount the target
root at `/mnt` and its boot partition at `/mnt/boot` before using
`sudo nixos-enter --root /mnt`. Mount commands depend on the real filesystem,
UUIDs, and any subvolumes; do not copy the device names from another machine.
Do not format anything during recovery.

The editable configuration remains at `/mnt/srv/nixos-family-installer` when
mounted from the live system. The original Calamares files are under
`/mnt/etc/nixos.calamares`. Preserve `/mnt/etc/ssh/ssh_host_ed25519_key`; replacing
it breaks the verified host identity and any grants tied to that key.

### Rebuilds or automatic updates fail

On the family computer, inspect:

```sh
journalctl -u nixos-upgrade.service -n 100 --no-pager
readlink /run/current-system
readlink -f /etc/nixos
```

Confirm the exact hostname is registered on this repository's `family-stable`
branch. Build a candidate before switching. For a manual
local configuration build, use `nixos-rebuild build --flake /etc/nixos#dad-laptop`
with the real hostname. If registration has not happened, continue using the
local flake and leave managed updates disabled.

## Instructions for an assisting agent

Read [AGENTS.md](AGENTS.md), then locate the current stage in this guide. On
a stick, these documents are under `/etc/nixos-family-installer`, and the setup
session copies them into its `Setup` project. On an installed family computer,
they are in `/srv/nixos-family-installer`. A stick contains the guide from its
own build, which can differ from GitHub.

Before choosing commands, establish these facts:

- Are you on Ivan's workstation, a generic stick, Ivan's own stick, or the
  installed family computer? On a stick, is a personal bundle unlocked
  (`cat /run/family-installer.ready`)?
- Who is at the keyboard, and what remote connection survives a reboot?
- What are the chosen primary username, owner setting, and unique hostname?
- Which exact disk may be erased, and what data must remain available?
- Has the host been registered on `family-stable`, and which access grants have
  actually been approved?

Use read-only commands to answer what you can. Ask for missing choices and the
person's confirmation of the actual disk before destructive operations. Explain
that Calamares starts writing at **Install**. Do not infer permission to format
from this README or from a disk's position in `lsblk`.

Guide the person through the graphical flow. Keep private passwords, provider
logins, disk passphrases, private keys, and Tailscale credentials out of public
logs. The public enrollment request is sufficient for the initial review.
Installation success does not depend on personal secret access.

After a failure, record what already happened before retrying. After success,
verify a boot from the installed disk, the primary account, flakes, the
configuration path, and the absence of inherited personal data. Report any
untested hardware, desktop, access, or recovery behavior explicitly.

When handing support to another agent, include the stage, media commit,
username, hostname, approved disk, connection method, exact error, and
registration status. Include only public key fingerprints. Do not include
passwords or private key material.

## Maintain the installer

This repository is standalone: Ivan's checkout is `~/projects/nixos-portable`.
Dotfiles consumes `nixosModules.portable` through its `nixos-portable` flake
input, so after publishing a change here, update that input in dotfiles
(`nix flake update nixos-portable` in `/srv/dotfiles/nixos`) and rebuild
Ivan's stick. Keep credentials and anything specific to Ivan in dotfiles; the
generic stick must stay credential-free.

The safe shared profile for installed computers is `modules/user-profile.nix`.
It imports only its local options and aliases. The target copies this whole
repository into `/srv/nixos-family-installer`, so modules must not import
anything outside it. It does not evaluate the dotfiles workstation flake,
fetch its private inputs, or require a Taffybar checkout. Nixpkgs and Home
Manager stay locked to 26.05 here.

The modules in `nixosModules.portable` must work with whatever Nixpkgs the
caller uses: dotfiles evaluates them with its own nixos-unstable. Agent
packages default to this flake's pins; callers may replace them through
`familyInstaller.agentTools.packages`.

Run the provided checks:

```sh
nix develop --command just fmt-check
nix develop --command just lint
nix develop --command just test
nix flake check
nix build .#calamares-extensions
```

`just check` combines formatting, lint, Python tests, and flake evaluation.
`nix flake check` also builds the checks. An image build alone does not prove
that installation succeeds. For behavior changes, run `just vm` and test the
first boot, personal setup, the graphical choices, partitioning and
encryption, completion, reboot, login, target configuration, and personal-data
exclusions before promoting the release. For changes that touch the shared
module, also build Ivan's stick from dotfiles (`just rescue-usb-build`).

Promote a reviewed commit by fast-forwarding `family-stable` and pushing it.
Do not force-push the release branch. A stick only changes when it is rebuilt
(`nixos-rebuild switch` on the stick) or rewritten. Updating GitHub alone does
not update an already-written stick.

## Implementation reference

| File or output | Responsibility |
| --- | --- |
| `modules/portable.nix` | The stick: live user, desktop, hardware support, rescue kit, Tailscale, SSH |
| `modules/usb-image.nix` | Partition layout, systemd-boot, the repart image, and first-boot setup |
| `modules/personal-setup.nix` | **Start personal setup**, bundle unlocking, and the isolated setup home |
| `modules/agent-tools.nix` | T3 Code, Codex, and Claude Code |
| `modules/calamares.nix` | Installer packages, customization, and installed guide |
| `calamares/owner.conf` | Ivan or Another person selection |
| `calamares/family-validate/` | Identity validation before disk operations |
| `scripts/patch_calamares.py` | Checked integration points in the pinned upstream installer |
| `scripts/prepare_media.py` | Writing sticks and adding personal bundles from a trusted computer |
| `scripts/provisioning.py` | Bundle unlocking, credential handoff, and target first boot |
| `scripts/prepare_target.py` | Target source, machine definition, host identity, and final configuration link |
| `modules/managed-system.nix` | Registered-machine update options and retention defaults |
| `machines/<hostname>/` | Reviewed machine registrations |
| `modules/user-profile.nix` | Safe shared primary-user profile |
| `nixosModules.portable` | The stick module, carrying this flake's agent pins |
| `nixosConfigurations.portable` | The generic stick |
| `packages.x86_64-linux.usb-image` | Raw image of the generic stick |

The installed filesystem contains:

| Path | Contents |
| --- | --- |
| `/srv/nixos-family-installer` | Release source plus the generated machine directory, with no Git metadata |
| `/etc/nixos` | Relative link to that local flake |
| `/etc/nixos.calamares` | Original generated configuration and hardware files |
| `/etc/ssh/ssh_host_ed25519_key` | Permanent private host key |
| `/etc/ssh/ssh_host_ed25519_key.pub` | Matching public key |
| `/var/lib/nixos-family-installer/enrollment.json` | Public identity, key, empty secret request, and pending-registration status |

The copied source is editable by root, not a Git checkout. It is a
self-contained flake with no parent-directory imports or submodule dependency.

The installer sets the target's initial `system.stateVersion` from its own
pinned NixOS release, even when the stick runs a newer release. The installer
preserves Calamares' generated disks, bootloader, desktop, locale, and account
settings. Calamares sets the chosen passwords separately. Preparing the flake
preserves an existing generated host key when retried. Finishing moves the
original configuration aside and links `/etc/nixos` to the local flake.
Unrelated existing checkouts and backups cause an error rather than being
overwritten. Calamares itself leaves out the disk holding the running `/`, so
it does not offer the stick as an installation target.

The installer's original code is MIT licensed. Bundled NixOS, Calamares, and
other dependencies retain their upstream licenses.
