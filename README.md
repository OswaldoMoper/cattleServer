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

**One thing follows from that and is worth knowing before the first deploy.** The unit runs under `ProtectSystem = "strict"`, so it can only write where it is told. When the settings are in Nix the module reads them and grants the paths they name; a credential it cannot read, so all it grants is `stateDir`. If the configuration inside that credential puts the backups, the logs or `known_hosts` anywhere else, name those paths in `extraReadWritePaths`:

```nix
services.cattleServer.extraReadWritePaths = [ "/srv/backup" ];
```

Getting this wrong does not look like a permissions error. The unit fails at step `NAMESPACE` before the program runs, so the journal shows a restart loop with nothing explaining it. The other options are `package`, `user`, `group`, `stateDir` and `protectHome`, all with sensible defaults.

`configuration/cattleServer.nix` shows both shapes. `nix flake show` lists everything the flake exports; it needs `--allow-import-from-derivation`, because the Haskell build is a haskell.nix one. `nixos-rebuild` does not.

### Anywhere else

`nix build` produces `result/bin/cattleServer`, wrapped so that `openssh`, `rsync` and `coreutils` are on its `PATH`. Locally the service runs `ssh-keygen`, `ssh-keyscan`, `rsync`, `ssh` -- rsync is told to use it as its transport -- and `rm`. The wrapper covers those four packages' worth. It does not provide a shell: if `alertCommand` is set, the `sh` that runs it comes from the ambient `PATH`, which under systemd is the default one.

On the machine being backed up the service needs `pg_dump`, `mkdir`, a shell, and **rsync**.

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
- `knownHosts` is the file described below. Unlike almost everything else it has **no default in the program**: a hand-written configuration that omits the key does not parse, and the service logs a configuration error rather than starting. The NixOS module fills it in for you, at `<stateDir>/known_hosts`.

The module also points `logDir` at `<stateDir>/cattleServer-Logs` rather than the default above, so that the state a backup schedule depends on lives where systemd manages it.

Note that `appConfig.name` names the log file, the backup directory and that success marker, so renaming an application has the same effect.

## Scheduling

Each application has its own `backupFrequency`, and two settings decide when the service looks:

- `checkEvery`, minutes between passes, 30 by default. This bounds how *late* a backup can be, not how often one happens: a pass only acts on the applications that are due, and one that finds nothing due costs a single log file read.
- `startupDelay`, minutes before the first pass, also 30. **So by default nothing happens for the first half hour after the service starts.** It is not stuck.

Setting `startupDelay` to zero makes the first pass happen at startup. On a machine with no log yet that means backing up immediately, since nothing records a previous backup -- worth knowing before pairing it with `Restart = "always"`.

### One backup, now

```sh
cattleServer --once my-app /etc/cattleServer.json
```

Backs up one application whether or not its window has passed, and exits. It is for whatever has to know a backup happened before it does something else -- a deploy that is about to change the machine being backed up, for instance -- and cannot wait for the next pass.

The exit code is the answer, and the three cases are deliberately distinct:

| Code | Meaning |
| --- | --- |
| `0` | the backup was recorded: the dump arrived complete, the uploads came with it, and `latest` points at it |
| `1` | it was attempted and did not work. The reason is on standard error and in the log |
| `2` | it was never attempted: the command line could not be read, there is no usable configuration, or no application goes by that name |

**`1` and `2` are not the same answer**, and a caller that treats them alike loses the distinction that matters: one says the backup failed, the other says nobody looked.

The run writes to the same log as any other backup, so it also moves that application's window -- the daemon will not immediately repeat what was just copied.

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
| The site being gone while the machine is fine | `watch` and `alertCommand` |
| One unreachable host stopping all the others | `connectTimeout`, 30s by default |
| Noticing a file has gone bad | `verifyEvery`, against the manifest |
| **A file going bad on this disk** | **Only an independent lineage** -- see below |
| **This disk dying** | **Nothing here.** A copy has to leave the machine |

The fifth row is the one worth reading twice. Because unchanged files are hardlinked between generations, thirty generations of a file that never changed are **thirty names for one piece of data**. If that data goes bad, all thirty go with it. Keeping more generations protects against deletion and against bad changes upstream; it does not protect against the disk.

What does protect against it is a second lineage: another entry in `apps` with its own `appConfig.name`, and ideally a different schedule. Separate names mean separate directories, and `--link-dest` never reaches across them, so the two copies share nothing. That independence is exactly what it costs -- the second lineage is a full copy.

And the last row is not something this service can fix. Every generation lives on one filesystem, so however many there are, one failure takes all of them. A backup that has never left the machine it backs up to is one disk away from not existing.

### Knowing rather than assuming

Three of those rows are about finding out, and all three are off unless asked for.

Every backup carries a `manifest.sha256` of everything in it, written once the backup is complete. Set `verifyEvery` to a number of hours and one backup **per application** is re-read each pass and compared against its own manifest. Which one rotates on its own: the least recently checked is always next. It costs reading a whole backup, which is why it is opt-in -- the hashing is not the expensive part, the disk is.

The manifest is in the format `sha256sum` reads, so a backup can also be checked without this program at all:

```sh
cd backup/prueba/latest && sha256sum -c manifest.sha256
```

And `alertAfter`, a number of hours, with `alertCommand`, runs something when an application has gone that long without a successful backup -- one command per window, not one per pass, and a backup that succeeds resets it. A machine that has never backed up counts as overdue, which is deliberate: a deployment that never worked is the one you most want to hear about.

### Watching the site

A backup proves the machine answered `ssh`. Whether anybody can open the site is a different question with its own answer: a certificate expires, a proxy stops forwarding, a name falls out of its zone, and every backup keeps succeeding throughout. Give an application a `watch` and each pass asks the site the way a visitor would.

```nix
watch = {
  url       = "https://example.org";
  addresses = [ "203.0.113.10" ];
  failures  = 2;
  certificateDays = 14;
};
```

What it finds is one of six things, and they are six because each one belongs to somebody different:

| What it found | Whose it is |
| --- | --- |
| The name does not resolve | The registrar account: the name is out of its zone |
| It resolves somewhere else | The DNS, or whatever was put in front of it |
| The name does not answer, but the machine does | The edge: a proxy, a certificate, a firewall |
| Neither answers | Whoever operates the machine |
| It answered, on a certificate close to expiry | Whoever operates the machine: the renewal is failing |
| It answered | Nobody, unless the status is 400 or worse |

`certificateDays` is how close to expiry a certificate that still works may get before it counts as a bad check, fourteen by default: Let's Encrypt renews at thirty, so fourteen left means the renewal has been failing for two weeks. It is asked only of an `https` URL that answered, on a connection of its own that reads the date and trusts nothing -- the request that answered already validated the chain. A certificate that could not be read is logged with the reason and is not a bad check, since the visitor got through. One that has already expired fails the request itself, and is reported as the name not answering.

Telling the third from the fourth is the whole reason to watch from another machine, and it is why the machine is asked over plain HTTP: a certificate is issued to the name and never to the address, so asking the address over HTTPS fails however healthy the machine is, and would blame it for what the edge is doing. The limit that follows is worth knowing: a machine that serves only 443 is reported as not answering. Redirects are not followed either -- a 301 to the name is the machine answering, and following it would put the name back under test.

`addresses` is what the name is expected to resolve to. Leave it out to accept any, which is what a site behind a proxy needs: it resolves to the proxy's network rather than to the machine, so naming the machine's address there would raise an alert on every single pass.

`failures` is how many consecutive bad checks it takes, two by default, so the gap a deploy or a reboot leaves does not raise one. The alert goes through the same `alertCommand`, once when the count is reached rather than once per pass -- an alert that repeats every few minutes is one people learn to ignore. A good check clears the count.

An application may have a `watch` and no `backupFrequency`, which watches a site without ever copying it. One that asks for neither is refused when the configuration is read, by name.

Backups are incremental. rsync transfers only what changed since the last one, and hardlinks the rest against the two previous backups -- two, so that one interrupted generation does not force a full copy of the next -- and so each directory reads as a complete tree while costing only the difference. Three generations of a tree with one changed file take the space of one tree plus that file, not three trees.

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

**Nothing from the network.** `hostKeyPolicy = "strict"` refuses a host it does not recognise rather than asking the network who it is. Note that it does not stop the service writing: a key you declared in `hostKeys` is still installed, because you are the one who said what it should be. What `strict` rules out is `ssh-keyscan`. So `strict` with declared keys is the strongest combination, and `strict` with none is a host that must already be in the file.

The order is fixed and does not depend on the policy: an entry already present is never touched, then keys declared in the configuration, then -- only under `accept-new` -- whatever `ssh-keyscan` answers.

No policy ever replaces an entry that already exists. If a host's key changes, the connection fails and says so, which is the point.

## Development

`nix develop` gives a shell with GHC, `stack`, `ghcid` and `openssh`.

Note that `nix build` builds from the *git tree*: a new file that has not been `git add`ed is invisible to it, and shows up as a missing module.
