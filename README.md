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

`nix build` produces `result/bin/cattleServer`, wrapped so that `openssh`, `rsync` and `coreutils` are on its `PATH`. The service shells out to `ssh-keygen`, `ssh-keyscan`, `rsync`, `rm`, and to `sh` if an alert command is configured, so those have to be reachable.

**rsync must also be installed on the machine being backed up.** The service checks over the SSH session it already has open and says so if it is missing. If it is installed but not on the short `PATH` a non-interactive `ssh host command` gets -- which is the usual case on NixOS -- name it with `remoteRsyncPath` rather than editing a shell profile over there.

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

```text
backup/prueba/2026-09-05T07/                    the backup taken at 07:00
backup/prueba/2026-09-05T07/yesod-project.sql   the database dump
backup/prueba/2026-09-05T07/upload/             the uploads directory
backup/prueba/latest -> 2026-09-05T07           a link to the newest one
```

The name is a truncated ISO 8601 timestamp, so `ls` lists backups in the order they were taken.

A backup only counts once everything has arrived. The dump is checked for the marker `pg_dump` writes when it finishes, and if it is not there the backup is not recorded and `latest` keeps pointing at the previous one. A transfer cut halfway leaves a directory behind, but never one that passes for a good backup.

The uploads directory keeps the name it has on the remote, so an
`appConfig.structure` of `/loads` arrives as `loads`.

The directory name is the date, and `latest` is a path that does not change between backups, so `readlink backup/prueba/latest` answers both "where is the current backup" and "when was it taken". The link is only moved once a backup has finished, so it never points at a half written one.

`deleteFrequency` removes every backup older than it, oldest first. On its own that is a hazard rather than a policy: it runs whether or not the backup before it succeeded, so a week of failing backups would see the last good one deleted on schedule and leave nothing at all. `keepAtLeast`, 2 by default, is the floor that stops it. Set it to zero to go back to deleting purely by the calendar.

## What each defence actually covers

Three different things get confused with each other, and only one of them is what most people mean by "I have backups".

| Against | What covers it |
| --- | --- |
| A file deleted or ruined at the source | Several generations: `deleteFrequency` and `keepAtLeast` |
| A transfer cut halfway | The completeness check on the dump |
| Backups quietly not happening at all | `alertAfter` and `alertCommand` |
| Noticing a file has gone bad | `verifyEvery`, against the manifest |
| **A file going bad on this disk** | **Only an independent lineage** -- see below |
| **This disk dying** | **Nothing here.** A copy has to leave the machine |

The fifth row is the one worth reading twice. Because unchanged files are hardlinked between generations, thirty generations of a file that never changed are **thirty names for one piece of data**. If that data goes bad, all thirty go with it. Keeping more generations protects against deletion and against bad changes upstream; it does not protect against the disk.

What does protect against it is a second lineage: another entry in `apps` with its own `appConfig.name`, and ideally a different schedule. Separate names mean separate directories, and `--link-dest` never reaches across them, so the two copies share nothing. That independence is exactly what it costs -- the second lineage is a full copy.

And the last row is not something this service can fix. Every generation lives on one filesystem, so however many there are, one failure takes all of them. A backup that has never left the machine it backs up to is one disk away from not existing.

### Knowing rather than assuming

Two of those rows are about finding out, and both are off unless asked for.

Every backup carries a `manifest.sha256` of everything in it, written once the backup is complete. Set `verifyEvery` to a number of hours and one backup per pass is re-read and compared against its own manifest. Which one rotates on its own: the least recently checked is always next. It costs reading a whole backup, which is why it is opt-in -- the hashing is not the expensive part, the disk is.

The manifest is in the format `sha256sum` reads, so a backup can also be checked without this program at all:

```sh
cd backup/prueba/latest && sha256sum -c manifest.sha256
```

And `alertAfter`, a number of hours, with `alertCommand`, runs something when an application has gone that long without a successful backup -- one command per window, not one per pass, and a backup that succeeds resets it. A machine that has never backed up counts as overdue, which is deliberate: a deployment that never worked is the one you most want to hear about.

Backups are incremental. rsync transfers only what changed since the last one, and hardlinks the rest against the previous backup, so each directory reads as a complete tree while costing only the difference. Three generations of a tree with one changed file take the space of one tree plus that file, not three trees.

The dump is the exception, and it is what decides how much disk to budget. It changes in its entirety every time, so `--link-dest` never shares it and every generation holds a full copy -- while rsync still sends only the difference, because two plain text dumps taken a few hours apart are nearly identical. Cheap on the network, linear on disk: reckon one whole dump per generation, and the uploads roughly once.

Two things follow from the hardlinks, and neither is obvious:

- **`du` on a single backup no longer answers "how much does this cost".** It counts blocks that backup shares with its neighbours. `du` over the whole application directory is still right, because it counts each block once.
- **Editing a file inside a backup changes it in every generation that shares it.** The service never does this -- rsync writes a temporary file and renames it, so it never modifies a shared inode -- but a person poking around can.

What does *not* change: every file is a complete, ordinary file. `cat`, `cp`, `tar`, or Windows over a network share all see the whole thing. Copying a backup elsewhere with `rsync -a` gives full copies at the destination; `rsync -aH` keeps them shared; `tar` records the links and recreates them.

rsync must be installed on **both** machines.

While a transfer runs, the log says how it is going, one line every `progressEvery` seconds plus one when it finishes:

```text
Progress: 1.0 MB of ~1.9 MB (52%), 25 of 45 files, 12.35MB/s, 01:35 elapsed, 0:00:12 left
Progress: 45 files checked, 1.9 MB transferred at 12.35MB/s, 01:47 elapsed
Success:  Total file size: 81500000 bytes
Success:  Total transferred file size: 2000000 bytes
Success:  total size is 81500000  speedup is 40.75
```

The closing line states what the transfer cost rather than repeating the last one at 100%, and a generation that finds its uploads unchanged closes with `nothing needed transferring` -- which is the incremental copy working perfectly, not a failure.

That last number is the one to look at. It is the size of the tree divided by what was actually sent, so a speedup in the tens means the incremental copy is doing its job, and one in the thousands means almost nothing needed sending. A speedup near 1 on every run means it is not working -- most likely because mtimes are not surviving the transfer, which is what makes rsync think every file has changed.

Only the running lines carry a tilde: rsync reports how far it has got and what fraction that is, never the total, so while a transfer is in flight the total is inferred. By the closing line it has arrived.

## Moving a backup, and restoring from one

`latest` is a relative link, so the whole directory can be copied, moved or mounted somewhere else and it still resolves.

The files inside are hardlinked between generations, which sounds like it should complicate moving them and does not: **a hardlinked file is an ordinary file**. There is no original and no copy, only one piece of data with more than one name, and every name is complete. `cat`, `cp`, an editor, Windows over a network share -- all of them see the whole file. Nothing can dangle.

What differs is only how much space arrives with it:

| | |
| --- | --- |
| `rsync -a` | full copies at the destination; correct, larger |
| `rsync -aH` | keeps the sharing, so the destination costs what the source did |
| `tar` | records the links and recreates them on extraction |
| `scp -r`, a file manager, a network share | full copies |

To restore the database:

```sh
psql -U <role> -d <database> < latest/<database>.sql
```

The role has to exist first. `pg_dump` covers one database and not the cluster's roles, passwords or tablespaces -- if those are declared in your NixOS configuration, rebuilding the host recreates them; if they are not, they exist only inside the cluster and are not in this backup.

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
