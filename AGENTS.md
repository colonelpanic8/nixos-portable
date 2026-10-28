# Agent instructions

Read [README.md](README.md) before assisting with installation, remote support,
registration, updates, or recovery. It is the operating guide for both the
person at the computer and an assisting agent. Start with its
[agent instructions](README.md#instructions-for-an-assisting-agent), then use
the section for the current stage. Establish which computer and environment
you are controlling before running commands.

Alex's current workflow starts on his MacBook Air: write the portable image
once, then add a personal bundle to the stick's `SETUP` volume. Read
[START-HERE.md](START-HERE.md) for the prompt used on the stick.

On every stick, this guide and README are installed under
`/etc/nixos-family-installer`. On a family target, the source copy is under
`/srv/nixos-family-installer`. Follow local machine instructions as well.

## Project scope

This repository builds a writable, portable NixOS USB stick that includes a
Calamares installer for family computers. Its flake is self-contained and
never evaluates Ivan's dotfiles. Dotfiles imports `nixosModules.portable` and
adds Ivan's personal layer (`nixos/machines/rescue-usb.nix`). Anything that
needs Ivan's credentials belongs there, not here. The target's account comes
from Calamares; owner (`ivan` / `other`) is independent of the login name.

## Structure

- `modules/portable.nix`: the stick (live user, desktop, hardware, rescue kit).
- `lib.mkStick` (flake.nix): a credential-free stick for a given user, hostname, and keys.
- `modules/usb-image.nix`: partition labels, systemd-boot, image, first boot.
- `modules/personal-setup.nix`: bundle unlocking into an isolated, in-memory home.
- `modules/calamares.nix`: reusable installer, package override, and support guide.
- `scripts/prepare_media.py`: write a stick; add a personal bundle to `SETUP`.
- `scripts/provisioning.py`: unlock, credential handoff, target first boot.
- `calamares/owner.conf`: owner selection page.
- `scripts/patch_calamares.py`: narrow, checked patch against pinned upstream.
- `scripts/prepare_target.py`: copy release source, preserve generated hardware
  and boot configuration, create permanent host identity and public request.
- `machines/<hostname>/`: reviewed registrations used by managed updates.
- `modules/user-profile.nix`: safe shared user preferences.

## Invariants

- Never import Ivan's dotfiles configuration into a family installation or
  the generic stick. The generic stick and image carry no credentials.
- Owner selection does not grant secret access. Do not import personal GPG,
  Git-sync, password-store, Syncthing or agent credentials implicitly.
- Keep Calamares' partition/encryption, user password, and bootloader handling.
- A personal target key may be generated on the trusted preparation computer
  and transported in the encrypted personal bundle. Never put it in Git, a
  Nix input, a public image, or logs. Enrollment requests contain public data.
- Only explicitly selected provider accounts are provisioned. Codex-only
  media is supported; do not require Claude login when it was omitted.
- Confirm USB identity before writing media and internal disk identity before
  installation. These are separate destructive operations.
- The personal setup session runs with its own in-memory `HOME`
  (`/run/family-setup`). Only credentials from that home are handed
  to a target. Never hand off the stick user's own logins, and never stop
  agent processes outside that session.
- Do not enable automatic updates until the host exists on the published
  `family-stable` ref. Never reboot unattended by default.
- For dotfiles changes (Ivan's stick), use only the primary `/srv/dotfiles`
  checkout and follow its root `AGENTS.md` and `nixos/AGENTS.md`. On an
  installed family computer, edit its local configuration as documented.
- Keep this flake self-contained. The target copies this repository, so imports
  outside it would break installed configurations.
- `nixosModules.portable` must evaluate with the caller's Nixpkgs; dotfiles
  uses nixos-unstable.
- Managed updates follow `github:colonelpanic8/nixos-portable` at the
  manually promoted `family-stable` ref.

## Development

Use Nix with flakes and `direnv allow`. No submodule checkout is needed.
Run `direnv exec . just check`, then `nix flake check` to build checks.
`just build` builds the image; `just vm` boots a disposable copy of it under
UEFI with a blank target disk. An image build is not proof that installation
succeeds: verify first boot, installation, reboot, primary account and
exclusions in the VM before shipping media.
