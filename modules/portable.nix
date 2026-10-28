{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.portable;
in {
  imports = [
    ./usb-image.nix
    ./calamares.nix
    ./agent-tools.nix
    ./personal-setup.nix
  ];

  options.portable = {
    liveUser = lib.mkOption {
      type = lib.types.str;
      default = "nixos";
      description = "Account that is logged in automatically on the stick.";
    };
    desktop = lib.mkOption {
      type = lib.types.enum ["plasma" "none"];
      default = "plasma";
      description = "Desktop provided by this module. Use none to supply your own.";
    };
    terminal = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = ["${pkgs.kdePackages.konsole}/bin/konsole" "--hold" "-e"];
      description = "Command prefix that runs a program in a graphical terminal.";
    };
    stickParameters = lib.mkOption {
      type = lib.types.nullOr (lib.types.attrsOf lib.types.anything);
      default = null;
      internal = true;
      description = "Arguments of lib.mkStick that built this stick, if any.";
    };
    tailscale.ephemeral = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Keep Tailscale state in memory, so every boot starts unenrolled.";
    };
  };

  config = lib.mkMerge [
    {
      networking.hostName = lib.mkDefault "portable";
      # Speech support otherwise pulls in every MBROLA voice (about 650 MiB).
      nixpkgs.overlays = [
        (_: prev: {
          mbrola-voices = prev.mbrola-voices.override {languages = ["*1"];};
        })
      ];
      networking.networkmanager.enable = true;
      time.timeZone = lib.mkDefault "America/Los_Angeles";
      system.stateVersion = lib.mkDefault lib.trivial.release;

      nix.settings = {
        experimental-features = ["nix-command" "flakes"];
        trusted-users = ["root" cfg.liveUser];
      };

      hardware.enableAllHardware = true;
      hardware.enableRedistributableFirmware = true;
      hardware.graphics.enable = true;
      boot.supportedFilesystems = ["btrfs" "cifs" "exfat" "ext4" "f2fs" "ntfs" "vfat" "xfs"];
      boot.swraid.enable = true;
      boot.swraid.mdadmConf = "PROGRAM ${pkgs.coreutils}/bin/true";
      zramSwap.enable = true;
      services.fstrim.enable = true;

      users.users.${cfg.liveUser} = {
        isNormalUser = true;
        extraGroups = ["audio" "disk" "input" "networkmanager" "video" "wheel"];
        initialHashedPassword = lib.mkDefault "";
      };
      security.sudo.wheelNeedsPassword = false;
      security.polkit.extraConfig = ''
        polkit.addRule(function(action, subject) {
          if (subject.isInGroup("wheel")) {
            return polkit.Result.YES;
          }
        });
      '';
      services.displayManager.autoLogin = {
        enable = true;
        user = cfg.liveUser;
      };

      # Reachable for remote help only over Tailscale.
      services.openssh = {
        enable = true;
        openFirewall = false;
        settings.PermitRootLogin = "no";
      };
      networking.firewall.interfaces.tailscale0.allowedTCPPorts = [22];
      services.tailscale = {
        enable = true;
        extraDaemonFlags = lib.mkIf cfg.tailscale.ephemeral ["--state=mem:"];
      };

      services.pipewire = {
        enable = true;
        alsa.enable = true;
        pulse.enable = true;
      };
      security.rtkit.enable = true;
      services.udisks2.enable = true;
      services.gvfs.enable = true;
      programs.zsh.enable = true;
      programs.nix-ld.enable = true;

      # On some hybrid-GPU laptops the display manager can reach graphical.target
      # while only simpledrm exists, and the session aborts before amdgpu/i915
      # registers the connector that drives the display. Wait for a real
      # connected DRM output, with a timeout so headless use still boots.
      systemd.services.portable-gpu-ready = {
        description = "Wait for a hardware DRM display before starting the display manager";
        before = ["display-manager.service"];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = pkgs.writeShellScript "wait-for-portable-gpu" ''
            attempt=0
            while (( attempt < 180 )); do
              for status in /sys/class/drm/card*-*/status; do
                [ -e "$status" ] || continue
                connector="''${status%/status}"
                connector="''${connector##*/}"
                card="''${connector%%-*}"
                driver_path="$(${pkgs.coreutils}/bin/readlink -f "/sys/class/drm/$card/device/driver" 2>/dev/null || true)"
                driver="''${driver_path##*/}"
                if [ "$driver" != "simple-framebuffer" ] && ${pkgs.gnugrep}/bin/grep -qx connected "$status"; then
                  echo "Hardware display $connector is ready on $driver"
                  exit 0
                fi
              done
              ${pkgs.coreutils}/bin/sleep 0.25
              (( attempt += 1 ))
            done
            echo "No connected hardware DRM display appeared after 45 seconds; continuing"
          '';
        };
      };
      systemd.services.display-manager = {
        requires = ["portable-gpu-ready.service"];
        after = ["portable-gpu-ready.service"];
      };

      familyInstaller.agentTools.enable = true;

      environment.systemPackages = with pkgs; [
        bashInteractive
        coreutils-full
        util-linux
        parted
        gptfdisk
        gparted
        cryptsetup
        lvm2
        mdadm
        btrfs-progs
        e2fsprogs
        xfsprogs
        dosfstools
        exfatprogs
        ntfs3g
        testdisk
        ddrescue
        smartmontools
        nvme-cli
        memtester
        stressapptest
        efibootmgr
        pciutils
        usbutils
        dmidecode
        ethtool
        wirelesstools
        networkmanager
        curl
        wget
        openssh
        rsync
        git
        gh
        just
        jq
        ripgrep
        fd
        file
        lsof
        strace
        tmux
        btop
        htop
        tree
        unzip
        zip
        p7zip
        zstd
        vim
        nano
      ];
    }

    (lib.mkIf (cfg.stickParameters != null) {
      environment.etc."nixos-portable/stick.json" = {
        text = builtins.toJSON cfg.stickParameters;
        mode = "0444";
      };
      environment.etc."nixos-portable/flake.nix" = {
        mode = "0444";
        text = ''
          {
            inputs.nixos-portable.url = "github:colonelpanic8/nixos-portable";
            outputs = {nixos-portable, ...}: {
              nixosConfigurations.stick =
                nixos-portable.lib.mkStick (builtins.fromJSON (builtins.readFile ./stick.json));
            };
          }
        '';
      };
      environment.systemPackages = [
        (pkgs.writeShellScriptBin "portable-update" ''
          exec sudo nixos-rebuild switch --refresh --no-write-lock-file \
            --flake path:/etc/nixos-portable#stick "$@"
        '')
      ];
    })

    (lib.mkIf (cfg.desktop == "plasma") {
      # The live user has an empty password, so a lock screen only gets in the way.
      environment.etc."xdg/kscreenlockerrc".text = ''
        [Daemon]
        Autolock=false
        LockOnResume=false
      '';
      services.desktopManager.plasma6 = {
        enable = true;
        enableQt5Integration = false;
      };
      services.displayManager.plasma-login-manager.enable = true;
      environment.plasma6.excludePackages = [pkgs.kdePackages.plasma-workspace-wallpapers];
      programs.kde-pim.enable = false;
      environment.systemPackages = [pkgs.firefox];
    })
  ];
}
