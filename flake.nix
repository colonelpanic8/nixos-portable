{
  description = "Portable NixOS USB stick with a graphical family installer";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-utils.url = "github:numtide/flake-utils";
    agent-nixpkgs.url = "github:NixOS/nixpkgs/4975466d324710c576dc11ad614684e6bd8cad8e";
    t3code = {
      url = "github:colonelpanic8/t3code/2797e64ebf29577a6297d9f7c6fdad6538d39658";
      inputs.nixpkgs.follows = "agent-nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };
    codex.url = "github:sadjow/codex-cli-nix/8dc8656b82ed75c9f76002f1368415b1e8471264";
    claude.url = "github:sadjow/claude-code-nix/c932f70402686f018d829534d71f9e8ba7859cfb";
  };

  outputs = inputs @ {
    self,
    nixpkgs,
    home-manager,
    flake-utils,
    ...
  }: let
    mkMachine = system: machine:
      nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = {familyInputs = inputs;};
        modules = [
          home-manager.nixosModules.home-manager
          ./modules/user-profile.nix
          ./modules/managed-system.nix
          ./modules/agent-tools.nix
          machine
        ];
      };
    machineNames = builtins.filter (
      name: builtins.pathExists (./machines + "/${name}/default.nix")
    ) (builtins.attrNames (builtins.readDir ./machines));
    # Usable from other flakes: the agent tool pins travel with the module.
    portableModule = {
      imports = [./modules/portable.nix];
      _module.args.familyInputs = inputs;
    };
    # A stick with no credentials. Its parameters are recorded on the stick so
    # `portable-update` rebuilds the same stick.
    mkStick = {
      user ? "nixos",
      hostname ? "portable",
      authorizedKeys ? [],
      persistentTailscale ? false,
    } @ parameters:
      nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          portableModule
          {
            portable = {
              liveUser = user;
              tailscale.ephemeral = !persistentTailscale;
              stickParameters = parameters;
            };
            networking.hostName = hostname;
            users.users.${user}.openssh.authorizedKeys.keys = authorizedKeys;
          }
        ];
      };
    portable = mkStick {};
  in
    {
      lib = {inherit mkMachine mkStick;};
      nixosModules = {
        default = ./modules/managed-system.nix;
        portable = portableModule;
      };
      nixosConfigurations =
        (builtins.listToAttrs (map (name: {
            inherit name;
            value = mkMachine "x86_64-linux" (./machines + "/${name}/default.nix");
          })
          machineNames))
        // {inherit portable;};
    }
    // flake-utils.lib.eachDefaultSystem (system: let
      pkgs = import nixpkgs {inherit system;};
      python = pkgs.python3.withPackages (ps: [ps.ruff ps.pyyaml]);
      testMachine = owner: updates: extra:
        mkMachine system ({...}: {
          imports = [extra];
          myModules.primaryUser = "dad";
          myModules.userProfile.owner = owner;
          networking.hostName = "family-test";
          system.stateVersion = "26.05";
          fileSystems."/" = {
            device = "/dev/disk/by-label/nixos";
            fsType = "ext4";
          };
          boot.loader.grub.devices = ["/dev/vda"];
          familyInstaller.updates.enable = updates;
        });
      profileCheck = owner: let
        cfg = (testMachine owner false {}).config;
        home = cfg.home-manager.users.dad;
        normalUsers = builtins.attrNames (nixpkgs.lib.filterAttrs (_: user: user.isNormalUser) cfg.users.users);
      in
        assert cfg.myModules.primaryUser == "dad";
        assert normalUsers == ["dad"];
        assert cfg.networking.firewall.enable;
        assert !(cfg.system.autoUpgrade.enable);
        assert !(cfg ? age);
        assert !(home.systemd.user.services ? git-sync-rs);
        assert !(home.systemd.user.services ? import-gpg-key);
        assert !(home.home.file ? ".password-store");
        assert builtins.all (a: a.assertion) cfg.assertions;
        assert (home.programs.git.settings.user or {})
        == (
          if owner == "ivan"
          then {
            name = "Ivan Malison";
            email = "IvanMalison@gmail.com";
          }
          else {}
        );
          pkgs.writeText "${owner}-profile-check" (builtins.toJSON {
            inherit normalUsers;
            primaryUser = cfg.myModules.primaryUser;
            failures = map (a: a.message) (builtins.filter (a: !a.assertion) cfg.assertions);
          });
      installerConfig =
        (nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            ./modules/calamares.nix
            ({...}: {
              boot.isContainer = true;
              system.stateVersion = "26.05";
              users.users.rescue-operator.isNormalUser = true;
            })
          ];
        }).config;
      installerCheck = assert !(installerConfig ? isoImage);
      assert !installerConfig.services.desktopManager.plasma6.enable;
      assert !installerConfig.services.displayManager.autoLogin.enable;
      assert installerConfig.programs.partition-manager.enable;
      assert installerConfig.security.polkit.enable;
      assert installerConfig.security.wrappers.pkexec.enable;
      assert builtins.attrNames (nixpkgs.lib.filterAttrs (_: user: user.isNormalUser) installerConfig.users.users) == ["rescue-operator"];
      assert builtins.all (a: a.assertion) installerConfig.assertions;
        pkgs.writeText "installer-module-check" (builtins.toJSON {
          guide = installerConfig.environment.etc."nixos-family-installer/README.md".source;
          extensions = installerConfig.system.build.familyCalamaresExtensions;
        });
      portableCheck = let
        cfg = portable.config;
        ssh = cfg.services.openssh;
        firewall = cfg.networking.firewall;
        normalUsers = builtins.attrNames (nixpkgs.lib.filterAttrs (_: user: user.isNormalUser) cfg.users.users);
      in
        assert normalUsers == ["nixos"];
        assert cfg.services.displayManager.autoLogin.user == "nixos";
        assert cfg.services.desktopManager.plasma6.enable;
        assert !ssh.openFirewall;
        assert !(builtins.elem 22 firewall.allowedTCPPorts);
        assert firewall.interfaces.tailscale0.allowedTCPPorts == [22];
        assert builtins.elem "--state=mem:" cfg.services.tailscale.extraDaemonFlags;
        assert builtins.elem "/run/family-installer/authorized_keys/%u" ssh.authorizedKeysFiles;
        assert cfg.fileSystems."/".device == "/dev/disk/by-label/PORTABLE-ROOT";
        assert cfg.fileSystems."/setup".device == "/dev/disk/by-label/SETUP";
        assert builtins.elem "nofail" cfg.fileSystems."/setup".options;
        assert cfg.boot.loader.systemd-boot.enable && !cfg.boot.loader.efi.canTouchEfiVariables;
        assert !(cfg ? age);
        assert builtins.all (a: a.assertion) cfg.assertions;
          pkgs.writeText "portable-stick-check" (builtins.unsafeDiscardStringContext cfg.system.build.toplevel.drvPath);
      provisionedCheck = tailscale: let
        helperKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureHelperKeyOnly helper";
        cfg =
          (testMachine "other" false {
            imports = [./modules/provisioned-system.nix];
            familyInstaller.provisioning = {
              enable = true;
              authorizedKeys = [helperKey];
              inherit tailscale;
            };
          }).config;
        ssh = cfg.services.openssh;
        firewall = cfg.networking.firewall;
        provision = cfg.systemd.services.family-provision;
        autoconnect = cfg.systemd.services.tailscaled-autoconnect;
      in
        assert firewall.enable;
        assert !ssh.openFirewall;
        assert ssh.ports == [22];
        assert !(builtins.elem 22 firewall.allowedTCPPorts);
        assert firewall.trustedInterfaces == ["lo"];
        assert firewall.interfaces.tailscale0.allowedTCPPorts == [22];
        assert ssh.settings.PasswordAuthentication == false;
        assert ssh.settings.KbdInteractiveAuthentication == false;
        assert ssh.settings.PermitRootLogin == "no";
        assert cfg.users.users.dad.openssh.authorizedKeys.keys == [helperKey];
        assert cfg.users.users.root.openssh.authorizedKeys.keys == [];
        assert cfg.services.tailscale.enable;
        assert provision.serviceConfig.UMask == "0077";
        assert builtins.elem "multi-user.target" provision.wantedBy;
        assert builtins.elem "display-manager.service" provision.before;
        assert (
          if tailscale
          then
            cfg.services.tailscale.authKeyFile
            == "/run/family-installer/tailscale-authkey"
            && builtins.elem "tailscaled-autoconnect.service" provision.before
            && builtins.elem "family-provision.service" autoconnect.requires
            && builtins.elem "family-provision.service" autoconnect.after
          else cfg.services.tailscale.authKeyFile == null && !(cfg.systemd.services ? tailscaled-autoconnect)
        );
        assert builtins.all (a: a.assertion) cfg.assertions;
          pkgs.writeText "provisioned-profile-check" (builtins.toJSON {
            inherit tailscale;
            sshInterfaces = builtins.attrNames (nixpkgs.lib.filterAttrs (_: i: builtins.elem 22 i.allowedTCPPorts) firewall.interfaces);
          });
      updateConfig = (testMachine "other" true {}).config;
      recordUpgrade = pkgs.writeShellScript "record-upgrade" ''
        printf '%s\n' "$@" > "$out"
      '';
      upgradeScript =
        nixpkgs.lib.replaceStrings
        ["${updateConfig.system.build.nixos-rebuild}/bin/nixos-rebuild"]
        ["${recordUpgrade}"]
        updateConfig.systemd.services.nixos-upgrade.script;
    in {
      formatter = pkgs.alejandra;
      devShells.default = pkgs.mkShell {
        packages = [pkgs.just pkgs.git pkgs.alejandra python pkgs.openssh pkgs.qemu pkgs.age pkgs.xz];
        OVMF = pkgs.OVMF.fd;
      };
      checks =
        {
          formatting = pkgs.runCommand "formatting" {nativeBuildInputs = [pkgs.alejandra];} ''
            alejandra --check ${./flake.nix} ${./modules} ${./modules/user-profile.nix}
            touch "$out"
          '';
          helper = pkgs.runCommand "installer-helper-tests" {nativeBuildInputs = [python pkgs.openssh pkgs.nix pkgs.age pkgs.xz];} ''
            cp -r ${./scripts} scripts
            cp -r ${./tests} tests
            cp -r ${./calamares} calamares
            cp ${./pyproject.toml} pyproject.toml
            export PYTHONPATH=$PWD/scripts
            ruff check scripts tests calamares
            ruff format --check scripts tests calamares
            python -m unittest discover -s tests -v
            touch "$out"
          '';
        }
        // nixpkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          other-user = profileCheck "other";
          ivan-user = profileCheck "ivan";
          installer-module = installerCheck;
          portable-stick = portableCheck;
          installer-state-version = pkgs.runCommand "installer-state-version" {} ''
            grep -F '    version = "${nixpkgs.lib.trivial.release}"' \
              ${installerConfig.system.build.familyCalamaresExtensions}/lib/calamares/modules/nixos/main.py
            touch "$out"
          '';
          provisioned-profile = provisionedCheck false;
          provisioned-tailscale-profile = provisionedCheck true;
          update-command = pkgs.runCommand "update-command" {} ''
            ${upgradeScript}
            test "$(sed -n '4p' "$out")" = '${updateConfig.system.autoUpgrade.flake}'
            test "$(wc -l < "$out")" -eq 4
          '';
        };
      packages = nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
        default = portable.config.system.build.usbImage;
        usb-image = portable.config.system.build.usbImage;
        calamares-extensions = portable.config.system.build.familyCalamaresExtensions;
      };
    });
}
