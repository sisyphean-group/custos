# Custos

Custos is a small USB authorization daemon and CLI. It is intentionally kept
simple and does not aim to support every feature under the sun.

## NixOS Module

The module implementation lives at `nix/module.nix`.

```nix
{ inputs, pkgs, ... }:

{
  imports = [
    inputs.custos.nixosModules.default
  ];

  services.custos = {
    enable = true;

    # Users which are allowed to control the daemon.
    controlUsers = [ "alice" ];

    policy.rules = [
      {
        name = "built-in keyboard";
        action = "allow";
        match = {
          vendorId = "6767";
          productId = "1337";
          connectType = "hardwired";
          isHub = false;
          interfaces.any = [ "03:*:*" ];
        };
      }
    ];
  };
}
```

The module:

- Generates `/etc/custos/config.toml` from `services.custos` daemon settings.
- Generates `/etc/custos/policy.toml` from `services.custos.policy`.
- Adds the `custos` package to `environment.systemPackages`.
- Creates a control group, default `custos`.
- Adds `services.custos.controlUsers` to that group.
- Creates the control socket directory with mode `2770`.
- Starts `systemd.services.custos` with
  `custos --daemon --config /etc/custos/config.toml`.
- Grants the service write access to the socket directory and the configured USB
  sysfs devices directory.

The socket itself is created by the daemon with mode `0660`. Users in the
configured control group can run daemon-backed CLI commands without root.

### Module Options

| Option                                          | Default                      | Meaning                                                                           |
| ----------------------------------------------- | ---------------------------- | --------------------------------------------------------------------------------- |
| `services.custos.enable`                        | `false`                      | Enable the daemon and generated files.                                            |
| `services.custos.package`                       | `null`                       | Package to run. Must be set by direct module users.                               |
| `services.custos.mode`                          | `"enforce"`                  | `"enforce"` writes sysfs authorization; `"dry-run"` logs/previews only.           |
| `services.custos.policyPath`                    | `"/etc/custos/policy.toml"`  | Policy TOML path written into the daemon config.                                  |
| `services.custos.socketPath`                    | `"/run/custos/control.sock"` | Unix socket used by the CLI.                                                      |
| `services.custos.sysfsRoot`                     | `"/sys"`                     | sysfs root used for USB scanning.                                                 |
| `services.custos.unsafeAllowEmptyPolicy`        | `false`                      | Permit enforcing startup without an endpoint allow rule.                          |
| `services.custos.defaultAction`                 | `"block"`                    | Fallback default if the policy file is absent and startup is otherwise permitted. |
| `services.custos.group`                         | `"custos"`                   | Group that owns the control socket directory.                                     |
| `services.custos.controlUsers`                  | `[ ]`                        | Users added to the control group.                                                 |
| `services.custos.controllers.authorizedDefault` | `"none"`                     | Desired controller `authorized_default`: `"keep"`, `"none"`, or `"all"`.          |
| `services.custos.controllers.restoreOnShutdown` | `false`                      | Restore controller `authorized_default` values on daemon exit.                    |
| `services.custos.policy.default`                | `"block"`                    | Policy default action when no rule matches.                                       |
| `services.custos.policy.rules`                  | `[ ]`                        | Ordered policy rules. First match wins.                                           |

The module keeps policy rendering simple and leaves semantic policy validation
to the `custos` binary at runtime. Option types still constrain obvious shape
errors, but lockout checks and empty-matcher checks are handled by
`custos validate` and daemon startup:

- In enforce mode, startup requires at least one `allow` rule that can match a
  non-hub endpoint, unless `unsafeAllowEmptyPolicy = true`.
- Every policy rule must have at least one match field.

## Commands

`custos` is both the daemon binary and the CLI.

### Daemon

```sh
custos --daemon
custos --daemon --config /etc/custos/config.toml
custos --daemon --dry-run
custos --daemon --unsafe-empty-policy
```

Daemon flags:

- `--daemon` starts enforcement.
- `--config PATH` selects the daemon config file.
- `--dry-run` overrides the loaded config mode to `dry-run`.
- `--unsafe-empty-policy` permits startup without an endpoint allow policy.

`--daemon` cannot be combined with subcommands or `--json`.

### Daemon-Backed CLI

These commands talk to the daemon over the Unix domain socket. Each accepts
`--socket PATH`; each supports `--json`.

```sh
custos status
custos devices
custos reload
custos dry-run-reload
custos allow <device-id>
custos block <device-id>
custos clear-override <device-id>
```

Command behavior:

- `status` prints daemon mode, device count, override count, socket path, and
  policy path as a report table.
- `devices` lists the daemon's current device snapshot and decision for each
  device as a report table.
- `reload` loads the policy from disk, validates it, applies it, and replaces
  the active policy if successful.
- `dry-run-reload` loads and validates the policy from disk, reports decisions,
  and does not replace the active policy.
- `allow <device-id>` creates a manual allow override and writes authorization
  immediately.
- `block <device-id>` creates a manual block override and writes authorization
  immediately.
- `clear-override <device-id>` removes a manual override and reapplies the
  active policy immediately.

Human output uses boxed Unicode report tables. JSON output is unchanged and is
intended for scripts. In device tables:

- `AUTHORIZED` is the current kernel/sysfs authorization state.
- `ACTION` is the policy or manual-override decision that Custos wants.

These can differ in `dry-run` output, before enforcement has run, if a device
disappears during a write, or if something outside Custos changes sysfs.

Device IDs are daemon-local runtime IDs from `custos devices`. They are stable
across refreshes for the same device identity, but they are not a persistent
policy identifier.

### Local Commands

These commands do not talk to the daemon.

```sh
custos dry-run
custos dry-run --config /path/to/config.toml
custos dry-run --json

custos validate
custos validate --config /path/to/config.toml
custos validate --dry-run
custos validate --unsafe-empty-policy

custos generate-policy
custos generate-policy --sysfs-root /sys
```

Command behavior:

- `dry-run` reads config and policy, scans current sysfs, and prints boxed
  reports showing what would be applied without writing sysfs.
- `validate` checks config, policy syntax, policy rule validation, and startup
  lockout rules, then prints a validation report.
- `generate-policy` scans currently connected devices and prints an initial
  allow policy to stdout.

`validate` and `generate-policy` do not support `--json`. `generate-policy`
intentionally prints raw TOML so it can be redirected to a policy file.

## How Enforcement Works

1. The daemon loads config from `/etc/custos/config.toml` by default. A missing
   config file falls back to built-in defaults.
2. The daemon loads the policy from `policy_path`.
3. Before enforcing, the daemon refuses to start unless the policy has at least
   one `allow` rule that can match a non-hub USB endpoint. This prevents a
   first-run lockout. Dry-run mode and `unsafe_allow_empty_policy = true` bypass
   this guard.
4. The daemon binds the control socket and opens the USB kernel uevent monitor.
   If the monitor cannot be opened, startup fails.
5. The daemon scans `${sysfs_root}/bus/usb/devices`, skipping root hubs and
   non-`usb_device` entries.
6. Each scanned device becomes a device state: the sysfs facts plus the current
   policy decision.
7. In enforce mode, the daemon writes each device's `authorized` sysfs file. In
   dry-run mode, it logs what it would write.
8. The daemon listens for USB kernel uevents and rescans after relevant USB
   device changes.
9. If the uevent monitor fails after startup, the daemon exits with an error so
   systemd can restart it.

Relevant uevents are USB device events with:

- `SUBSYSTEM=usb`
- `DEVTYPE=usb_device`
- `ACTION` in `add`, `bind`, `change`, `remove`, or `unbind`

The daemon logs device connections, removals, decision changes, explicit policy
allow/block decisions, manual overrides, and cleared overrides.

### Device Identity

Runtime device IDs are assigned by the daemon. The ID mapping is keyed by:

- sysfs path
- vendor ID
- product ID
- serial, if present

Manual overrides are keyed the same way. Overrides survive refreshes for the
same identity and are removed when the identity disappears from the current
snapshot.

### Hubs

With policy default `block`, hubs are allowed by default with reason
`USB hub passthrough`. This keeps downstream devices visible so the daemon can
evaluate and authorize them individually.

Add an explicit hub rule if you want different hub behavior:

```toml
[[rules]]
name = "block all hubs"
action = "block"

[rules.match]
is_hub = true
```

## Config TOML

Default config path:

```text
/etc/custos/config.toml
```

Example:

```toml
mode = "enforce"
policy_path = "/etc/custos/policy.toml"
socket_path = "/run/custos/control.sock"
sysfs_root = "/sys"
unsafe_allow_empty_policy = false
default_action = "block"

[controllers]
authorized_default = "none"
restore_on_shutdown = false
```

Fields:

| Field                             | Type                        | Default                      | Meaning                                                                    |
| --------------------------------- | --------------------------- | ---------------------------- | -------------------------------------------------------------------------- |
| `mode`                            | `"enforce"` or `"dry-run"`  | `"enforce"`                  | Whether to write sysfs or only preview/log.                                |
| `policy_path`                     | path string                 | `"/etc/custos/policy.toml"`  | Policy file to load.                                                       |
| `socket_path`                     | path string                 | `"/run/custos/control.sock"` | Daemon control socket.                                                     |
| `sysfs_root`                      | path string                 | `"/sys"`                     | Root used for sysfs scanning.                                              |
| `unsafe_allow_empty_policy`       | bool                        | `false`                      | Bypass first-run enforcement lockout.                                      |
| `default_action`                  | `"allow"` or `"block"`      | `"block"`                    | Default used only when the policy file is absent and startup is permitted. |
| `controllers.authorized_default`  | `"keep"`, `"none"`, `"all"` | `"none"`                     | Controller `authorized_default` handling.                                  |
| `controllers.restore_on_shutdown` | bool                        | `false`                      | Capture current controller state on startup and restore it on exit.        |

Controller `authorized_default` values map to sysfs writes:

- `"keep"`: do not touch controller defaults.
- `"none"`: write `0`.
- `"all"`: write `1`.

## Policy TOML

Default policy path:

```text
/etc/custos/policy.toml
```

Example:

```toml
default = "block"

[[rules]]
name = "built-in keyboard"
action = "allow"

[rules.match]
vendor_id = "feed"
product_id = "1307"
connect_type = "hardwired"
descriptor_hash = "base64-sha256-descriptor-hash"
is_hub = false

[rules.match.interfaces]
any = ["03:*:*"]
```

Policy fields:

| Field            | Type                   | Meaning                                              |
| ---------------- | ---------------------- | ---------------------------------------------------- |
| `default`        | `"allow"` or `"block"` | Action when no rule matches.                         |
| `rules`          | array                  | Ordered rules. First matching rule wins.             |
| `rules[].name`   | string                 | Non-empty rule name. Used in decisions and logs.     |
| `rules[].action` | `"allow"` or `"block"` | Action for matching devices.                         |
| `rules[].match`  | table                  | Device matcher. Must contain at least one criterion. |

Matcher fields use TOML snake_case:

| Field             | Meaning                                                                      |
| ----------------- | ---------------------------------------------------------------------------- |
| `vendor_id`       | Four hexadecimal USB vendor ID. Case-insensitive.                            |
| `product_id`      | Four hexadecimal USB product ID. Case-insensitive.                           |
| `serial`          | Exact USB serial string.                                                     |
| `product_name`    | Exact USB product string.                                                    |
| `connect_type`    | Exact kernel `connect_type`, such as `hardwired` or `hotplug`.               |
| `port_path`       | Exact sysfs USB port path, such as `1-2` or `3-1.4`.                         |
| `descriptor_hash` | Base64-encoded SHA-256 hash of the device `descriptors` file.                |
| `is_hub`          | Boolean hub matcher.                                                         |
| `interfaces.any`  | At least one listed interface pattern must match. Empty means no constraint. |
| `interfaces.all`  | Every listed interface pattern must match at least one device interface.     |

Interface patterns use `cc:ss:pp`, where each segment is two hex digits or `*`:

```toml
[rules.match.interfaces]
any = ["03:*:*"]
all = ["03:01:01", "03:00:*"]
```

Rule validation:

- Rule names cannot be empty.
- A matcher cannot be empty.
- `vendor_id` and `product_id` must be exactly four hex characters.
- String matcher values cannot be empty.
- Interface patterns must have exactly three segments.

## Starting Safely

The workflow for getting this project up and running is approximately:

1. Run `custos generate-policy > policy.toml` while the desired baseline devices
   are plugged in.
2. Review and edit the generated policy; remove devices you do not want to be
   allowed.
3. Create a `config.toml` that points `policy_path` at the reviewed policy.
4. Run `custos validate --config ./config.toml`.
5. Run `custos dry-run --config ./config.toml`.
6. Enable the NixOS module or start `custos --daemon --config ./config.toml` as
   superuser.

To intentionally test without a policy:

```sh
custos --daemon --dry-run --unsafe-empty-policy
```

Avoid enforcing an empty or unreviewed policy unless you have another way back
into the machine. WE ARE NOT RESPONSIBLE IF YOU BORK YOUR SYSTEM.

## Credits

This project is _heavily_ inspired by
[USBGuard](https://github.com/usbguard/usbguard). It is a reimplementation of
the same core idea, but with the goal of being _much_ smaller and simpler.

## License

This project is licensed under the GNU Affero General Public License v3.0 or
later (AGPL-3.0-or-later). Please refer to the LICENSE.md file for more details.
