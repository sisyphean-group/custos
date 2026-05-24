{

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    {
      self,
      nixpkgs,
      ...
    }:
    let
      inherit (nixpkgs) lib;
      forEachSystem = lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
      ];
      pkgsForEach = nixpkgs.legacyPackages;
    in
    {
      nixosModules = {
        custos =
          { lib, pkgs, ... }:
          {
            imports = [ ./nix/module.nix ];
            services.custos.package = lib.mkDefault self.packages.${pkgs.stdenv.hostPlatform.system}.custos;
          };
        default = self.nixosModules.custos;
      };

      packages = forEachSystem (
        system:
        let
          pkgs = pkgsForEach.${system};
          custos = pkgs.rustPlatform.buildRustPackage {
            pname = "custos";
            version = "0.1.0";
            src = lib.cleanSourceWith {
              src = ./.;
              filter =
                path: _type:
                let
                  name = baseNameOf path;
                in
                name != "target" && name != ".direnv";
            };
            cargoLock.lockFile = ./Cargo.lock;
            meta = {
              description = "NixOS-first USB authorization daemon";
              license = lib.licenses.gpl2Plus;
              mainProgram = "custos";
              platforms = lib.platforms.linux;
            };
          };
        in
        {
          inherit custos;
          default = custos;
        }
      );

      apps = forEachSystem (system: {
        custos = {
          type = "app";
          program = "${self.packages.${system}.custos}/bin/custos";
          meta.description = "Run the custos USB authorization CLI";
        };
        default = self.apps.${system}.custos;
      });

      checks = forEachSystem (
        system:
        let
          pkgs = pkgsForEach.${system};
          moduleEval = lib.nixosSystem {
            inherit system;
            modules = [
              self.nixosModules.custos
              (
                { ... }:
                {
                  services.custos = {
                    enable = true;
                    mode = "dry-run";
                    controlUsers = [ "alice" ];
                    policy.rules = [
                      {
                        name = "built-in keyboard";
                        action = "allow";
                        match = {
                          vendorId = "feed";
                          productId = "1307";
                          connectType = "hardwired";
                          interfaces.any = [ "03:*:*" ];
                        };
                      }
                      {
                        name = "example explicit hub block";
                        action = "block";
                        match.isHub = true;
                      }
                    ];
                  };
                  system.stateVersion = "26.05";
                }
              )
            ];
          };
          customSocketEval = lib.nixosSystem {
            inherit system;
            modules = [
              self.nixosModules.custos
              (
                { ... }:
                {
                  services.custos = {
                    enable = true;
                    mode = "dry-run";
                    socketPath = "/run/custom-custos/control.sock";
                    sysfsRoot = "/var/lib/custom-custos-sys";
                  };
                  system.stateVersion = "26.05";
                }
              )
            ];
          };
          unsafeEval = lib.nixosSystem {
            inherit system;
            modules = [
              self.nixosModules.custos
              (
                { ... }:
                {
                  services.custos = {
                    enable = true;
                    mode = "enforce";
                    unsafeAllowEmptyPolicy = true;
                  };
                  system.stateVersion = "26.05";
                }
              )
            ];
          };
        in
        {
          nixos-module =
            pkgs.runCommand "custos-nixos-module"
              {
                controlGroupMembers = lib.concatStringsSep "," moduleEval.config.users.groups.custos.members;
                tmpfileRules = lib.concatStringsSep "\n" customSocketEval.config.systemd.tmpfiles.rules;
                readWritePaths = lib.concatStringsSep "\n" customSocketEval.config.systemd.services.custos.serviceConfig.ReadWritePaths;
              }
              ''
                grep -q 'mode = "dry-run"' ${moduleEval.config.environment.etc."custos/config.toml".source}
                grep -q 'action = "allow"' ${moduleEval.config.environment.etc."custos/policy.toml".source}
                grep -q 'is_hub = true' ${moduleEval.config.environment.etc."custos/policy.toml".source}
                grep -q 'unsafe_allow_empty_policy = true' ${
                  unsafeEval.config.environment.etc."custos/config.toml".source
                }
                case ",$controlGroupMembers," in
                  *,alice,*) ;;
                  *) exit 1 ;;
                esac
                printf '%s\n' "$tmpfileRules" | grep -q 'd /run/custom-custos 2770 root custos'
                printf '%s\n' "$readWritePaths" | grep -qx '/run/custom-custos'
                printf '%s\n' "$readWritePaths" | grep -qx '/var/lib/custom-custos-sys/bus/usb/devices'
                touch $out
              '';
        }
        // lib.optionalAttrs (system == "x86_64-linux") {
          custos-vm = import ./nix/tests/custos.nix { inherit pkgs self; };
        }
      );

      devShells = forEachSystem (system: {
        default = pkgsForEach.${system}.callPackage ./nix/shell.nix { };
      });
    };
}
