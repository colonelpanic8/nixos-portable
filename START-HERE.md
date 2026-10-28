# Set up this computer

After booting the portable stick, connect Wi-Fi or Ethernet. **Start personal
setup** opens by itself (or from the desktop), lists the bundles on the stick,
and asks for the bundle passphrase chosen on the Mac. It then opens T3 Code.
Use **Codex**; it has the account prepared on the Mac. Claude requires a
separate login if wanted later. Select the `Setup` project.

Paste this into a new Codex thread:

> Help me install NixOS on this computer. Read README.md and AGENTS.md here
> first. We are on the portable USB stick, not the Mac that prepared it. Read
> /run/family-installer.ready to identify the prepared hostname. Use Another
> person, login alex, and that hostname in Calamares. Check network access and
> Codex authentication. Identify the actual internal disk by model, serial and
> capacity; show me what will be deleted and ask me to confirm that disk and
> that needed files are backed up before any destructive command or Install.
> The intended plan is to erase the confirmed internal disk, use automatic
> partitioning, and install Plasma. Explain optional disk encryption and let
> me enter my own passwords privately. Open family-installer and help me
> through the graphical installer. Preserve the prepared host key and agent
> enrollment. Do not import Ivan's personal secrets, Git-sync or GPG keys.
> Check installation completion, then help me reboot from the internal disk
> and verify my account, T3 Code, Codex, and any prepared Tailscale support.

The bundle passphrase, disk-encryption passphrase, and login password have
different purposes. Keep them private. Installation erases the selected
internal disk; writing the stick already erased the stick. These are two
separate decisions. **Install** in Calamares starts writing immediately.

This bundle needs no call to Ivan to approve an SSH host key or re-encrypt the
included agent credentials. Network access and a valid provider subscription
are still required. If Tailscale enrollment was not included, local Codex
assistance still works. Do not infer that a running Tailscale daemon is enrolled.

After installation, boot the internal disk and sign in as the chosen user.
T3 Code and the prepared agent credentials are initialized at first boot.
The setup session lives in memory on the stick and ends at reboot; save any
needed notes into the installed user's home before rebooting.

When Calamares reports success, reboot into the installed system before using
the agent again. The installer stops live Codex and transfers its latest credentials at the end
of installation. The agent disconnecting at that point is expected. Afterwards,
delete this computer's bundle from the stick's SETUP volume.
