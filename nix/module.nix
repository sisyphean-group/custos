{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    types
    ;

  cfg = config.services.custos;
  socketDir = dirOf cfg.socketPath;
  usbDevicesPath = "${cfg.sysfsRoot}/bus/usb/devices";
  tomlFormat = pkgs.formats.toml { };

  compactAttrs =
    value:
    if builtins.isAttrs value then
      lib.filterAttrs (_: v: v != null) (lib.mapAttrs (_: v: compactAttrs v) value)
    else if builtins.isList value then
      map compactAttrs value
    else
      value;

  renderMatch =
    match:
    compactAttrs {
      vendor_id = match.vendorId;
      product_id = match.productId;
      serial = match.serial;
      product_name = match.productName;
      connect_type = match.connectType;
      port_path = match.portPath;
      descriptor_hash = match.descriptorHash;
      is_hub = match.isHub;
      interfaces = {
        any = match.interfaces.any;
        all = match.interfaces.all;
      };
    };

  renderRule =
    rule:
    compactAttrs {
      inherit (rule) name action;
      match = renderMatch rule.match;
    };

  configFile = tomlFormat.generate "custos-config.toml" (compactAttrs {
    mode = cfg.mode;
    policy_path = cfg.policyPath;
    socket_path = cfg.socketPath;
    sysfs_root = cfg.sysfsRoot;
    unsafe_allow_empty_policy = cfg.unsafeAllowEmptyPolicy;
    default_action = cfg.defaultAction;
    controllers = {
      authorized_default = cfg.controllers.authorizedDefault;
      restore_on_shutdown = cfg.controllers.restoreOnShutdown;
    };
  });

  policyFile = tomlFormat.generate "custos-policy.toml" {
    default = cfg.policy.default;
    rules = map renderRule cfg.policy.rules;
  };

  matcherOptions =
    { ... }:
    {
      options = {
        vendorId = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "USB vendor ID matcher as four hexadecimal characters.";
        };

        productId = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "USB product ID matcher as four hexadecimal characters.";
        };

        serial = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "USB serial string matcher.";
        };

        productName = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "USB product string matcher.";
        };

        connectType = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Kernel-reported USB port connect_type matcher.";
        };

        portPath = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "USB sysfs port path matcher, such as 1-2 or 3-1.4.";
        };

        descriptorHash = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Base64-encoded SHA-256 hash of the USB descriptors file.";
        };

        isHub = mkOption {
          type = types.nullOr types.bool;
          default = null;
          description = "Match USB hubs. By default, hubs pass through default-block policy.";
        };

        interfaces = mkOption {
          type = types.submodule {
            options = {
              any = mkOption {
                type = types.listOf types.str;
                default = [ ];
                description = "Interface patterns where at least one must match.";
              };

              all = mkOption {
                type = types.listOf types.str;
                default = [ ];
                description = "Interface patterns where every listed pattern must match.";
              };
            };
          };
          default = { };
          description = "USB interface class/subclass/protocol matchers.";
        };
      };
    };

  ruleOptions =
    { ... }:
    {
      options = {
        name = mkOption {
          type = types.str;
          description = "Human-readable rule name.";
        };

        action = mkOption {
          type = types.enum [
            "allow"
            "block"
          ];
          description = "Rule action.";
        };

        match = mkOption {
          type = types.submodule matcherOptions;
          default = { };
          description = "Device matcher for this rule.";
        };
      };
    };
in
{
  options.services.custos = {
    enable = mkEnableOption "the custos USB authorization daemon";

    package = mkOption {
      type = types.nullOr types.package;
      default = null;
      defaultText = lib.literalExpression "self.packages.\${system}.custos";
      description = "custos package to run.";
    };

    mode = mkOption {
      type = types.enum [
        "enforce"
        "dry-run"
      ];
      default = "enforce";
      description = "Daemon mode.";
    };

    policyPath = mkOption {
      type = types.str;
      default = "/etc/custos/policy.toml";
      description = "Path to the generated policy TOML.";
    };

    socketPath = mkOption {
      type = types.str;
      default = "/run/custos/control.sock";
      description = "Unix domain socket used by the custos CLI.";
    };

    sysfsRoot = mkOption {
      type = types.str;
      default = "/sys";
      description = "Root path for sysfs scanning.";
    };

    unsafeAllowEmptyPolicy = mkOption {
      type = types.bool;
      default = false;
      description = "Allow enforcing startup with an empty policy.";
    };

    defaultAction = mkOption {
      type = types.enum [
        "allow"
        "block"
      ];
      default = "block";
      description = "Default action used when no rule matches.";
    };

    group = mkOption {
      type = types.str;
      default = "custos";
      description = "Group allowed to connect to the control socket.";
    };

    controlUsers = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        User accounts that should be added to the custos control group so they
        can run the CLI against the system daemon without root.
      '';
      example = [
        "alice"
      ];
    };

    controllers = {
      authorizedDefault = mkOption {
        type = types.enum [
          "keep"
          "none"
          "all"
        ];
        default = "none";
        description = "Controller authorized_default handling policy.";
      };

      restoreOnShutdown = mkOption {
        type = types.bool;
        default = false;
        description = "Whether controller authorization state should be restored on shutdown.";
      };
    };

    policy = {
      default = mkOption {
        type = types.enum [
          "allow"
          "block"
        ];
        default = "block";
        description = "Policy default action.";
      };

      rules = mkOption {
        type = types.listOf (types.submodule ruleOptions);
        default = [ ];
        description = "Ordered custos policy rules. First match wins.";
        example = [
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
        ];
      };
    };
  };

  config = mkIf cfg.enable {
    users.groups.${cfg.group}.members = cfg.controlUsers;

    environment.systemPackages = [ cfg.package ];
    environment.etc."custos/config.toml".source = configFile;
    environment.etc."custos/policy.toml".source = policyFile;

    systemd.tmpfiles.rules = [
      "d ${socketDir} 2770 root ${cfg.group} - -"
    ];

    systemd.services.custos = {
      description = "Custos USB authorization daemon";
      wantedBy = [ "multi-user.target" ];
      after = [
        "systemd-tmpfiles-setup.service"
        "systemd-udevd.service"
      ];

      serviceConfig = {
        Type = "simple";
        ExecStartPre = "${pkgs.coreutils}/bin/install -d -m 2770 -o root -g ${cfg.group} ${socketDir}";
        ExecStart = "${lib.getExe cfg.package} --daemon --config /etc/custos/config.toml";
        Restart = "on-failure";
        RestartSec = "1s";
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ReadWritePaths = [
          socketDir
          usbDevicesPath
        ];
      };
    };
  };
}
