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
* The uploads directory arrives under the name it has on the remote instead of
  always being called `upload`. A restore that reaches for `latest/upload`
  needs the real name now, unless that is what it was called anyway.
* Every line also goes to standard output, so `journalctl -u cattleServer`
  shows the service. The log file is unchanged.
* A backup is one directory named for its timestamp, `2026-09-05T07`, rather
  than four nested ones. Deletion follows: it reaches every backup older than
  `deleteFrequency` instead of only the one that fell on the cutoff, so a day
  the service was down no longer leaves backups behind forever. **The first
  pass after upgrading clears whatever backlog that left**, down to
  `keepAtLeast`.
* An application whose name contains a space no longer creates two
  directories.
* Backups in the old nested layout are renamed into the new one on the first
  pass, and the `latest` link is repointed after. Nothing has to be moved by
  hand, and a rename that cannot be done leaves that backup where it is for
  the next pass to retry.
* Backups are pulled with `rsync --link-dest` rather than `scp`, so only what
  changed is transferred and the rest is hardlinked against the previous
  backup. **rsync is now required on both machines.** `du` on one backup
  counts blocks it shares with its neighbours; `du` over the whole
  application directory is still right.

## 0.1.0.0 -- YYYY-mm-dd

* First version. Released on an unsuspecting world.
