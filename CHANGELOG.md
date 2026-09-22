# Revision history for cattleServer

## 0.11.0

### Installing and configuring

* The flake exports `nixosModules.default` and `overlays.default`. The service
  is configured through `services.cattleServer`, and no file has to be copied
  into anyone's configuration. The real configuration is kept out of the Nix
  store with `settingsFile`, which arrives as a systemd credential.
* The configuration file is found through a command line argument or
  `CATTLESERVER_CONFIG`, not only relative to the working directory, so the
  service no longer has to be started from one particular place.
* Failing to write the placeholder configuration is no longer fatal, which is
  the normal case once the file is managed by Nix or agenix.

### Trusting the remote host

* cattleServer maintains the `known_hosts` file itself, so a new machine no
  longer needs somebody to `ssh` in by hand first. Host keys can be declared
  in the configuration -- or seeded from the module with `knownHostsSeed` --
  or scanned on first use and checked against a pinned fingerprint. No policy
  ever replaces an entry that is already there, so a host whose key changed
  still fails.
* `connectTimeout` bounds how long reaching the remote may take, thirty
  seconds by default -- the same figure the transfers have always been given,
  so nothing moves until it is set. Opening the session had no bound at all,
  and the library that opens it is C code that cannot be interrupted from
  Haskell, so a host that swallows the packets -- switched off, behind a
  firewall that drops, a port nothing listens on -- stopped the service
  indefinitely, and with it every other application, because they are backed
  up one after another. Reaching the host is now checked with `ssh` first,
  under that bound. That check only ever refuses the answers that mean nobody
  was there -- timed out, refused, no route, unresolvable. A key that is not
  accepted, or a host key that changed, still goes through to libssh2, which
  is the one that should name what is wrong with it.
* A host that did not end up in `known_hosts` is no longer connected to. The
  refusal was written to the log and then ignored, so a `strict` policy facing
  an unknown host announced itself and opened the connection anyway -- libssh2
  refused it a moment later, so nothing was ever trusted, but the round trip
  was paid and the log said one thing while the code did another.

### Backups

* **A backup is one directory named for its timestamp**, `2026-09-05T07`,
  rather than four nested ones. Existing backups are renamed into the new
  shape on the first pass; nothing has to be moved by hand.
* **Backups are incremental.** rsync transfers only what changed and hardlinks
  the rest against the previous backup, so each directory reads as a complete
  tree while costing the difference. **rsync is now required on both
  machines**, and the service says so plainly if the remote lacks it.
  `remoteRsyncPath` names where it lives when a non-interactive ssh cannot
  find it.
* A `latest` link in each application's directory points at the newest
  completed backup. It is relative, so a backup tree can be copied or moved
  and it still resolves.
* The uploads directory arrives under the name it has on the remote rather
  than always being called `upload`, so `/loads` lands as `loads`.
* Transfers report progress: a line every `progressEvery` seconds carrying
  bytes, files, rate, elapsed and the time still expected, and a closing line
  saying what the transfer cost rather than repeating the last one at 100%. A
  generation that finds nothing changed closes with `nothing needed
  transferring`. Then the `--stats` speedup, which says whether the
  incremental copy is working.

### Keeping and checking them

* **Deletion reaches every backup older than `deleteFrequency`**, oldest
  first, where before it could only ever remove the one that fell exactly on
  the cutoff -- so a day the service was down left backups behind forever.
  **The first pass after upgrading clears whatever backlog that left.**
* `keepAtLeast`, 2 by default, is a floor under that: deletion runs whether or
  not the backup before it succeeded, so on its own a week of failing backups
  would end with nothing at all.
* A downloaded dump is checked for the marker `pg_dump` writes when it
  finishes. Without it the backup is not recorded and `latest` keeps pointing
  at the previous one, so a transfer cut halfway cannot pass for a good
  backup.
* Each backup carries a manifest of SHA-256 digests, in the format
  `sha256sum` reads, so it can be checked by hand as well. With `verifyEvery`
  set, one backup per pass is re-read and compared -- the only thing that
  turns "it was written correctly" into "it is still correct".
* `alertAfter` and `alertCommand` run something when an application has gone
  too long without a successful backup. Logging is not warning.

### Scheduling and output

* `--once <application>` backs up one application immediately, whether or not
  its window has passed, and exits: `0` when the backup was recorded, `1` when
  it was attempted and did not work, and `2` when it was never attempted --
  an unreadable command line, no usable configuration, or no application by
  that name. It is for a caller that has to know a backup happened before it
  does something else and cannot wait for the next pass. The backup goes into
  the same log as any other, so it also moves that application's window.
* An unrecognised option is now an error. Before, the first non-empty argument
  was taken as the configuration path, so a mistyped flag became a file name
  and the daemon reported a configuration problem that was really a typo.
* `checkEvery` and `startupDelay` replace the half hour that was compiled in.
  Both default to it, so nothing changes until they are set.
* Every line also goes to standard output, with a syslog priority, so
  `journalctl -u cattleServer` shows the service and can be filtered by level.
  The log file keeps its exact shape, because the scheduler reads its own
  markers back out of it.

### Fixes

* A missing external program fails one backup instead of stopping the service.
  Nothing here can express a runtime dependency on `rsync` or `openssh`, so a
  missing one was possible and would have thrown.
* An application whose name contains a space no longer creates two
  directories.
* An unexpected directory name no longer throws where a number was expected.
* The SSH session is closed when authentication fails, instead of being leaked
  once per failure for the lifetime of the daemon.
* Values from the configuration are quoted before being interpolated into the
  remote shell command.

## 0.1.0.0 -- YYYY-mm-dd

* First version. Released on an unsuspecting world.
