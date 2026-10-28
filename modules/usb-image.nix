{
  config,
  lib,
  modulesPath,
  pkgs,
  ...
}: let
  efiArch = pkgs.stdenv.hostPlatform.efiArch;
  ukiFile = config.system.boot.loader.ukiFile;
  registration = "/nix-path-registration";
  closure = pkgs.closureInfo {rootPaths = [config.system.build.toplevel];};
  setupReadme = pkgs.writeText "SETUP-README.txt" ''
    This volume belongs to a portable NixOS USB stick.

    Personal setup bundles (*.age) prepared on another computer go here.
    They are encrypted with the passphrase chosen during preparation.
    Start personal setup on the stick lists them.
  '';
in {
  imports = ["${modulesPath}/image/repart.nix"];

  fileSystems."/" = {
    device = "/dev/disk/by-label/PORTABLE-ROOT";
    fsType = "ext4";
    autoResize = true;
    options = ["noatime"];
  };
  # FAT labels hold only 11 characters; the GPT partition label holds this one.
  fileSystems."/boot" = {
    device = "/dev/disk/by-partlabel/PORTABLE-ESP";
    fsType = "vfat";
    options = ["fmask=0077" "dmask=0077"];
  };
  fileSystems."/setup" = {
    device = "/dev/disk/by-label/SETUP";
    fsType = "vfat";
    # Readable by the stick's administrators; bundles are passphrase-encrypted.
    options = [
      "nofail"
      "x-systemd.device-timeout=5s"
      "uid=0"
      "gid=${toString config.ids.gids.wheel}"
      "fmask=0137"
      "dmask=0027"
    ];
  };
  boot.growPartition = true;
  swapDevices = [];

  boot.initrd.availableKernelModules = ["ehci_pci" "sd_mod" "uas" "usb_storage" "xhci_pci"];
  boot.loader = {
    efi.canTouchEfiVariables = false;
    systemd-boot = {
      enable = true;
      configurationLimit = lib.mkDefault 5;
      memtest86.enable = true;
    };
  };

  image.repart = {
    name = lib.mkDefault "nixos-portable";
    # Most of the minimized ext4 root is still free space; xz is what Etcher reads.
    compression = {
      enable = true;
      algorithm = "xz";
      level = 3;
    };
    partitions = {
      "00-esp" = {
        contents = {
          "/EFI/BOOT/BOOT${lib.toUpper efiArch}.EFI".source = "${pkgs.systemd}/lib/systemd/boot/efi/systemd-boot${efiArch}.efi";
          "/EFI/Linux/${ukiFile}".source = "${config.system.build.uki}/${ukiFile}";
        };
        repartConfig = {
          Type = "esp";
          Format = "vfat";
          Label = "PORTABLE-ESP";
          SizeMinBytes = "1G";
          SizeMaxBytes = "1G";
        };
      };
      # Microsoft basic data, so macOS and Windows mount it for adding bundles.
      "10-setup" = {
        contents = {
          "/README.txt".source = setupReadme;
          "/.nixos-portable".source = pkgs.writeText "nixos-portable-marker" "1\n";
        };
        repartConfig = {
          Type = "ebd0a0a2-b9e5-4433-87c0-68b6b72699c7";
          Format = "vfat";
          Label = "SETUP";
          SizeMinBytes = "256M";
          SizeMaxBytes = "256M";
        };
      };
      # Last, so growpart can extend it over the rest of the stick.
      "20-root" = {
        storePaths = [config.system.build.toplevel];
        contents.${registration}.source = "${closure}/registration";
        repartConfig = {
          Type = "root";
          Format = "ext4";
          Label = "PORTABLE-ROOT";
          Minimize = "guess";
        };
      };
    };
  };

  # The image boots a UKI directly. Register its store paths, create the system
  # profile, and replace the UKI with ordinary systemd-boot generations.
  systemd.services.portable-first-boot = {
    wantedBy = ["sysinit.target"];
    before = ["sysinit.target" "shutdown.target" "nix-daemon.socket" "nix-daemon.service"];
    after = ["local-fs.target"];
    conflicts = ["shutdown.target"];
    unitConfig = {
      DefaultDependencies = false;
      ConditionPathExists = registration;
    };
    restartIfChanged = false;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ${lib.getExe' config.nix.package.out "nix-store"} --load-db < ${registration}
      touch /etc/NIXOS
      ${lib.getExe' config.nix.package.out "nix-env"} -p /nix/var/nix/profiles/system --set /run/current-system
      install -d -m 0700 /var/lib/portable
      touch /var/lib/portable/install-bootloader
      rm -f ${registration}
    '';
  };
  systemd.services.portable-install-bootloader = {
    wantedBy = ["multi-user.target"];
    after = ["local-fs.target" "portable-first-boot.service"];
    unitConfig.ConditionPathExists = "/var/lib/portable/install-bootloader";
    restartIfChanged = false;
    serviceConfig.Type = "oneshot";
    environment.NIXOS_INSTALL_BOOTLOADER = "1";
    script = ''
      /nix/var/nix/profiles/system/bin/switch-to-configuration boot
      rm -f /boot/EFI/Linux/${ukiFile}
      rm /var/lib/portable/install-bootloader
    '';
  };

  system.build.usbImage = config.system.build.image;
}
