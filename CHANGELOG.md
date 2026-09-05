# Revision history for cattleServer

## 0.11.0

* cattleServer maintains the `known_hosts` file itself, so a new machine no
  longer needs somebody to `ssh` into the remote host by hand first. Host keys
  can be declared in the configuration, or scanned on first use and checked
  against a pinned fingerprint. Neither ever replaces an entry already there.
* The flake exports `nixosModules.default` and `overlays.default`. The service
  is configured through `services.cattleServer`, with the real configuration
  kept out of the Nix store via `settingsFile`.
* The configuration file is found through an argument or
  `CATTLESERVER_CONFIG`, not only relative to the working directory, and the
  log directory is a setting rather than a path relative to it.
* `scp` is resolved on `PATH` instead of an absolute NixOS-only path, and uses
  the remote user, port and `known_hosts` file from the configuration.
* A missing `openssh` fails one backup instead of stopping the service.
* `checkEvery` and `startupDelay` replace the half hour that was compiled in.
  Both default to it, so nothing changes until they are set.
* `keepAtLeast`, 2 by default, is a floor under `deleteFrequency`. Deletion
  went by date and ran whether or not the backup before it succeeded, so a
  week of failing backups would have left nothing at all.
* A `latest` link in each application's backup directory points at the newest
  backup, and is only moved once one has finished.

## 0.1.0.0 -- YYYY-mm-dd

* First version. Released on an unsuspecting world.
