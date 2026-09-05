# cattleServer

Turns a web application's server from a *pet* into *cattle*: a daemon that periodically logs into it over SSH, dumps its PostgreSQL database, pulls the dump and the uploads directory back, and prunes backups once they are old enough.

It backs up any number of applications from one configuration file, each on its own schedule.

## Install

### On NixOS

Add the flake as an input and import the module:

```nix
{
  inputs.cattleServer.url = "github:OswaldoMoper/cattleServer";

  imports = [ inputs.cattleServer.nixosModules.default ];

  services.cattleServer = {
    enable = true;
    settings = {
      localHost = {
        hostName = "backup-puller";
        userName = "cattleserver";
        userHome = "/var/lib/cattleServer";
      };
      apps = [{
        appConfig      = { name = "example-daily"; structure = "/upload"; };
        databaseConfig = { name = "postgres"; structure = "yesod-project"; };
        serviceConfig  = {
          remoteHost      = { hostName = "backup.example.org";
                              userName = "admin";
                              userHome = "/home/admin"; };
          keyDirectory    = { name = "example-ed25519"; structure = "/run/agenix"; };
          portNumber      = 22;
          backupFrequency = { unit = "Hours"; times = 8; };
          deleteFrequency = { unit = "Days";  times = 10; };
        };
      }];
    };
  };
}
```

`settings` renders into the Nix store, which is world readable on the host. A real configuration names a host, a database and a key path, so keep it out of there with `settingsFile`, which takes precedence and arrives as a systemd credential:

```nix
services.cattleServer.settingsFile = config.age.secrets.cattleServerConfig.path;
```

`configuration/cattleServer.nix` shows both shapes. `nix flake show` lists everything the flake exports; it needs `--allow-import-from-derivation`, because the Haskell build is a haskell.nix one. `nixos-rebuild` does not.

### Anywhere else

`nix build` produces `result/bin/cattleServer`, wrapped so that `openssh` and `coreutils` are on its `PATH`. The service shells out to `ssh-keygen`, `ssh-keyscan`, `scp`, `mkdir` and `rm`, so those have to be reachable.

## Configuring

Outside NixOS the configuration is a JSON file, found in this order:

1. the first command line argument -- `cattleServer /etc/cattleServer.json`;
2. the `CATTLESERVER_CONFIG` environment variable;
3. `./config/cattleServer.json`, relative to the working directory.

Deleting it makes the service write a placeholder in its place, unless the path is not writable, which is the normal case when it is managed by Nix. `config/example.json` shows a filled in file and `config/documentation.json` describes every field.

The file is re-read on every cycle, so an edit takes effect without a restart.

Two fields decide where the service keeps its state:

- `logDir` holds the service log and one log per application. It defaults to `<localHost.userHome>/cattleServer-Logs`. This is not only a log: the service decides when the next backup is due by reading back its own success markers, so pointing it somewhere new makes it take a backup immediately.
- `knownHosts` is the file described below.

Note that `appConfig.name` names the log file, the backup directory and that success marker, so renaming an application has the same effect.

## Scheduling

Each application has its own `backupFrequency`, and two settings decide when the service looks:

- `checkEvery`, minutes between passes, 30 by default. This bounds how *late* a backup can be, not how often one happens: a pass only acts on the applications that are due, and one that finds nothing due costs a single log file read.
- `startupDelay`, minutes before the first pass, also 30. **So by default nothing happens for the first half hour after the service starts.** It is not stuck.

Setting `startupDelay` to zero makes the first pass happen at startup. On a machine with no log yet that means backing up immediately, since nothing records a previous backup -- worth knowing before pairing it with `Restart = "always"`.

## What a backup looks like, and what survives

Backups land in a dated tree under `<localHost.userHome>/backup/<app>/`:

```
backup/prueba/2026/09/05/T07/     the backup taken at 07:00 on 2026-09-05
backup/prueba/latest -> .../T07   a link to the newest one
```

The directory name is the date, and `latest` is a path that does not change between backups, so `readlink backup/prueba/latest` answers both "where is the current backup" and "when was it taken". The link is only moved once a backup has finished, so it never points at a half written one.

`deleteFrequency` removes old backups by date. On its own that is a hazard rather than a policy: it runs whether or not the backup before it succeeded, so a week of failing backups would see the last good one deleted on schedule and leave nothing at all. `keepAtLeast`, 2 by default, is the floor that stops it -- enough that a corrupt newest backup still has one behind it. Set it to zero to go back to deleting purely by the calendar.

Note that a backup is a full copy: the uploads directory is fetched in its entirety every time, with no incremental transfer.

## Trusting the remote host

libssh2 refuses a host that is not in the `known_hosts` file, so this used to need somebody to `ssh` in by hand once per machine. The service does it itself now, in one of three ways.

**Declare the host's key.** The most predictable one, and a host's public key is not a secret, so it can be declared even when the rest of the configuration is encrypted:

```nix
services.cattleServer.knownHostsSeed = [
  "backup.example.org ssh-ed25519 AAAAC3Nz..."
];
```

or per connection, in `serviceConfig.hostKeys`. Either way the service never has to trust what the network answers, and it repairs itself: delete the state directory and the entry comes back.

**Trust on first use.** `hostKeyPolicy = "accept-new"`, the default, runs `ssh-keyscan` and adds what the host offers. Set `hostKeyFingerprint` to `SHA256:...` and only a key matching it is accepted.

**Nothing.** `hostKeyPolicy = "strict"` never writes to the file. Use it when the entry is already there by other means.

No policy ever replaces an entry that already exists. If a host's key changes, the connection fails and says so, which is the point.

## Development

`nix develop` gives a shell with GHC, `stack`, `ghcid` and `openssh`.

Note that `nix build` builds from the *git tree*: a new file that has not been `git add`ed is invisible to it, and shows up as a missing module.
