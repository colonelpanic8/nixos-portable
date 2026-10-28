{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.portable;
  provisioning = "${pkgs.python3}/bin/python3 ${../scripts}/provisioning.py";
  unlock = pkgs.writeShellApplication {
    name = "family-unlock";
    runtimeInputs = [pkgs.age pkgs.openssh pkgs.tailscale pkgs.jq];
    text = ''
      exec ${provisioning} unlock "$1" ${lib.escapeShellArg cfg.liveUser}
    '';
  };
  start = pkgs.writeShellApplication {
    name = "family-start";
    runtimeInputs = [pkgs.coreutils];
    text = ''
      shopt -s nullglob
      home=/run/family-setup
      if [[ ! -f /run/family-installer.ready ]]; then
        bundles=(/setup/*.age)
        if (( ''${#bundles[@]} == 1 )); then
          sudo ${lib.getExe unlock} "''${bundles[0]}"
        elif (( ''${#bundles[@]} > 1 )); then
          echo "Choose the computer to set up:"
          select bundle in "''${bundles[@]}"; do
            [[ -n "$bundle" ]] && break
          done
          sudo ${lib.getExe unlock} "$bundle"
        else
          sudo install -d -m 0700 -o "$(id -u)" -g "$(id -g)" "$home"
          echo "No personal bundle on the SETUP volume. Sign in to an agent yourself."
        fi
      fi
      mkdir -p "$home/Setup"
      install -m 0644 /etc/nixos-family-installer/{README.md,AGENTS.md,START-HERE.md} "$home/Setup/"
      cd "$home/Setup"
      # A separate, in-memory home keeps the stick's own logins out of the
      # accounts handed to the installed computer.
      HOME="$home" exec /run/current-system/sw/bin/t3code-desktop --password-store=basic
    '';
  };
  desktop = pkgs.makeDesktopItem {
    name = "family-start";
    desktopName = "Start personal setup";
    exec = lib.escapeShellArgs (cfg.terminal ++ [(lib.getExe start)]);
    terminal = false;
    icon = "utilities-terminal";
    categories = ["System"];
  };
  autostart = pkgs.writeShellScript "family-autostart" ''
    shopt -s nullglob
    bundles=(/setup/*.age)
    if (( ''${#bundles[@]} )) && [[ ! -f /run/family-installer.ready ]]; then
      exec ${lib.escapeShellArgs (cfg.terminal ++ [(lib.getExe start)])}
    fi
  '';
in {
  environment.systemPackages = [unlock start desktop];
  environment.etc."xdg/autostart/family-setup.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=Start personal setup
    Exec=${autostart}
  '';
  environment.etc."nixos-family-installer/START-HERE.md".source = ../START-HERE.md;
  services.openssh.authorizedKeysFiles = ["/run/family-installer/authorized_keys/%u"];
}
