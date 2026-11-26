# Deploying a service on exeslim

A service on exeslim is a systemd unit named `svc-<app>.service`, which the base
image hardens. This file says what such a unit needs, how to install it on a
running VM or in an image derived from exeslim, and what its failures look
like.

On a VM this file is `/usr/share/doc/exeslim/deploying.md`, as of the VM's
image. Its links are relative to the repository,
https://github.com/tho/exeslim.

## The model

One service per VM: the profile lets it use up to 80% of the VM's memory. Its
binary, unit and config are root-owned, so the service can read but not change
them, and live outside `/home`, which it cannot see. Its state lives in
`/var/lib/<app>`, created by `StateDirectory=`, and its secrets in root-only
files under `/etc/<app>/`. Nothing else on the VM belongs to the service.

There are two ways to put it there. [On the VM](#installing-on-the-vm), with
`sudo`: quick, and what an agent working on the VM does.
[In a derived image](#installing-from-a-derived-image): reproducible, checked
in CI, and the way to replace a VM, or run the service on several, without
redoing the setup. The unit is the same either way.

## The unit

A unit declares only what the app needs:

```ini
[Unit]
Description=my-service

[Service]
ExecStart=/usr/local/bin/my-service
StateDirectory=my-service
LoadCredential=token:/etc/my-service/token

[Install]
WantedBy=multi-user.target
```

- **Name it `svc-<app>.service`.** The profile is a prefix drop-in,
  `/etc/systemd/system/svc-.service.d/50-hardening.conf`, applied only to units
  whose name starts with `svc-`. Any other name runs unhardened, and nothing
  warns you.
- **No `User=` and no hardening settings.** The drop-in supplies them. Drop-ins
  win for single-value keys (`Restart=always` becomes `on-failure`), but list
  keys merge, so `RestrictAddressFamilies=AF_UNIX` in the unit *widens* the
  profile, and a `User=exedev` makes `DynamicUser=` run the service as `exedev`.
- **Install the code outside `/home`.** `/home`, `/root` and `/run/user` are
  empty to the service, so an `ExecStart=` under `~exedev` fails with
  `203/EXEC`. A binary goes in `/usr/local/bin`, an interpreted app's code under
  `/opt/<app>`, config under `/etc/<app>/`, all root-owned.
- **Listen on `127.0.0.1:8000`.** exe.dev's proxy defaults to port 8000 on this
  image and connects from inside the VM. Other ports between 3000 and 9999 are
  reachable at `https://<vm>.exe.xyz:<port>/` by users with access to the VM.
- **State goes in `StateDirectory=`**, passed as `$STATE_DIRECTORY`. Under
  `DynamicUser=` the real directory is `/var/lib/private/<app>`, reached through
  a `/var/lib/<app>` symlink. The rest of the filesystem is read-only to the
  service (writes fail with `EROFS`) apart from a private `/tmp`, emptied when
  the unit stops. To move the state to another VM, `tar` that directory between
  stopped units. The dynamic UID differs per VM, and systemd chowns the
  directory on start.
- **`HOME` is unset**, and the user's home directory is `/`, read-only. An app
  that keeps its files under `~` with no setting to move them can start through
  the base image's wrapper,
  `ExecStart=/usr/local/bin/svc-exec /usr/local/bin/my-service`, which sets
  `HOME`, `XDG_CONFIG_HOME`, `XDG_DATA_HOME` and `XDG_STATE_HOME` under
  `$STATE_DIRECTORY` (and `XDG_CACHE_HOME` to `CacheDirectory=` if the unit has
  one), each unless the unit already sets it. It needs `StateDirectory=` and a
  command it can run. Without either, the wrapper exits 78, which the profile
  does not restart, so the unit fails. An app that looks its home up in the user
  database instead of `$HOME` (OpenSSH, for one) still gets `/`. It sets paths
  only. Never export a credential from a wrapper, which puts it in the
  environment of every child.
- **Secrets come from `LoadCredential=`.** The unit names a root-only file and
  the app reads `$CREDENTIALS_DIRECTORY/token`, byte for byte (mind a trailing
  newline). Until the file exists the unit fails with `243/CREDENTIALS`, the
  expected state of a fresh VM ([provisioning](#provisioning-a-secret) is
  below). Never put secrets in the image, the unit or `Environment=`: anyone who
  can pull the image or run `systemctl show` can read them there.
- **Unix sockets work.** `sd_notify()` reaches systemd, so `Type=notify` and
  `WatchdogSec=` do what they say. A local database is reachable over its
  socket, with peer authentication mapping the service's user, `svc-<app>`
  (resolvable through nss-systemd), to a role. `/dev/log` works too, though
  stdout (journald) is simpler. The system bus is inaccessible.
- **An app can sandbox itself.** Landlock and `seccomp(2)` are allowed, since a
  process can use them only to restrict itself. Sandboxes that need user
  namespaces or setuid (bubblewrap, Firejail, Chrome's own) cannot start. Many
  apps carry on unconfined when their sandbox fails, some while reporting it
  enabled, and Landlock also needs the kernel to enforce it: test that the
  sandbox refuses something before relying on it.

What the profile sets, and why, is in the drop-in itself, one comment per
setting ([`image/svc-hardening.conf`](../image/svc-hardening.conf) in the
repository). `systemd-analyze security` rates a unit under it at exposure 1.2
and the same unit without it at 9.4.

To loosen a setting on purpose, add a drop-in that sorts after
`50-hardening.conf`: `svc-<app>.service.d/60-<what>.conf` in a derived image,
or `sudo systemctl edit svc-<app>` on a VM, which writes `override.conf`. A
change made on the VM is lost with it, so once the service has an image, put
the drop-in there.

## Installing on the VM

The base has no compiler: `sudo apt-get install` one and build in `~`, or copy
in a binary built elsewhere. Then install the binary and its unit, root-owned,
and start it:

```sh
sudo install -m 0755 my-service /usr/local/bin/my-service
sudo install -m 0644 svc-my-service.service /etc/systemd/system/svc-my-service.service
sudo systemctl daemon-reload
sudo systemctl enable --now svc-my-service
```

Check that it runs, is hardened, and answers:

```sh
systemctl status svc-my-service
systemd-analyze security --threshold=20 svc-my-service.service
curl -fsS http://127.0.0.1:8000/
```

The security check fails above exposure 2.0. A unit the drop-in missed scores
about 9.4.

To update, replace the binary with `mv`, which is atomic within one filesystem,
so the unit never restarts into a half-written file:

```sh
sudo install -m 0755 my-service /usr/local/bin/.my-service.new
sudo mv /usr/local/bin/.my-service.new /usr/local/bin/my-service
sudo systemctl restart svc-my-service
```

Keep the old binary beside it for rollback, since `Restart=` never gives up on
one that crashes. The exception is exit status 78 (`EX_CONFIG` in `sysexits.h`),
which the profile takes as a configuration error that a retry cannot fix: the
unit stays failed until `systemctl restart`. If the unit file changes too,
`sudo systemctl daemon-reload` before the restart.

### Provisioning a secret

The secret's owner provisions it, as root, without it appearing on a command
line or in an agent's transcript. On the VM (paste the secret, then Ctrl-D):

```sh
sudo install -d -m 0700 /etc/my-service
sudo install -m 0600 /dev/stdin /etc/my-service/token
sudo systemctl restart svc-my-service
```

From another machine, with the secret in a local file:

```sh
ssh <vm>.exe.xyz 'sudo install -d -m 0700 /etc/my-service && sudo install -m 0600 /dev/stdin /etc/my-service/token' <token
ssh <vm>.exe.xyz sudo systemctl restart svc-my-service
```

An agent asks the user to do this rather than handling the secret itself.

## Installing from a derived image

[`examples/hello`](../examples/hello) is the complete minimal case, and CI
publishes it as `ghcr.io/tho/exeslim-hello`. The derived Dockerfile builds a
static binary, copies it and the unit in, and enables the unit (the example pins
the Go image by version and digest, which Dependabot keeps current):

```dockerfile
ARG BASE=ghcr.io/tho/exeslim:<build-id>

FROM golang:<version> AS build
WORKDIR /src
COPY go.mod main.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /hello

FROM ${BASE}
COPY --from=build --chmod=0755 /hello /usr/local/bin/hello
COPY --chmod=0644 svc-hello.service /etc/systemd/system/svc-hello.service
RUN systemctl enable svc-hello.service
```

If the Dockerfile runs `apt-get` after `FROM`, end it with
`RUN : >/etc/machine-id`: package configuration can bake a machine ID into the
image, which every VM created from it would then share.

### Checking it in CI

`systemd-analyze security` scores the unit's effective settings, so a threshold
fails the build on a unit the drop-in missed and on most loosening, and the
output lists what it found. It runs inside the derived image without booting
it:

```sh
docker build --pull -t my-service .
docker run --rm my-service systemd-analyze security --offline=true --threshold=20 svc-my-service.service
```

Two things it does not catch: `User=exedev` beside `DynamicUser=` scores as a
fine static user, and a secret in `Environment=` is not its concern. Those stay
rules above. To also see the service start and answer, boot the image:

```sh
docker run -d --name my-service --privileged --tmpfs /run --tmpfs /run/lock my-service
# "degraded" is expected: systemd-growfs-root fails in Docker.
timeout 120 bash -c 'until [[ $(docker exec my-service systemctl is-system-running 2>/dev/null) =~ ^(running|degraded)$ ]]; do sleep 1; done'
# Only with LoadCredential=: Docker leaves mounts private, so share them, then provision.
docker exec my-service mount --make-rshared /
docker exec my-service bash -c 'install -d -m 0700 /etc/my-service && printf test | install -m 0600 /dev/stdin /etc/my-service/token'
docker exec my-service systemctl restart svc-my-service.service
docker exec my-service curl -fsS --retry 10 --retry-connrefused --retry-delay 1 http://127.0.0.1:8000/
```

### Deploying and updating

Create the VM from an immutable tag or digest,
[provision its secrets](#provisioning-a-secret), check
`systemctl status svc-<app>` and open `https://<vm>.exe.xyz/`.

The weekly exeslim rebuild does not reach your service by itself: rebuild the
derived image on a newer build id to pick up base patches.

**Stateless:** replace the VM (`ssh exe.dev rm`, then `new` under the same name)
and provision its secrets again, since they lived on the old VM. For no
downtime, create under another name, check, remove the old one.

**Stateful:** update in place, as [on the VM](#installing-on-the-vm): `scp`
the binary over and run the same `install`, `mv` and `restart` through
`ssh <vm>.exe.xyz`.

## When it fails

`journalctl -u svc-<app>` shows the app's output and systemd's reason.

| Symptom | Cause |
| --- | --- |
| `status=203/EXEC` | `ExecStart=` is under `/home`, missing, or not executable |
| `status=243/CREDENTIALS` | The `LoadCredential=` file does not exist yet |
| Exit 78, not restarted | `svc-exec` without `StateDirectory=` or a runnable command, or the app's own `EX_CONFIG` |
| `Read-only file system` | A write outside `$STATE_DIRECTORY` and `/tmp` |
| `Operation not permitted` from a system call | `SystemCallFilter=` or a capability the profile drops |
| `Address family not supported` | A netlink or packet socket, which `RestrictAddressFamilies=` refuses |
| A JIT crashes or will not start | `MemoryDenyWriteExecute=` (see [agent runtimes](#agent-runtimes)) |
| Files expected under `~` are missing | `HOME` is unset. Start through `svc-exec` |
| `/proc/meminfo` or `/proc/cpuinfo` missing | `ProcSubset=pid`. Loosen with `ProcSubset=all` |
| `Connection refused` on `127.0.0.1:9999` | The Shelley guard, on purpose |
| Exposure about 9.4 | The unit is not named `svc-<app>.service` |
| Runs as `exedev`, not `svc-<app>` | `User=` in the unit |

## Agent runtimes

An AI agent runtime runs shell commands its model chose as the service's own
user. The profile confines that user, not the app from itself: those commands
can read the app's config and credentials, `$CREDENTIALS_DIRECTORY` included,
and rewrite its policy. Only the app's own sandbox stands between them, so:

- **Turn on its Landlock or seccomp sandbox**, in a build that includes it.
- **Keep the workspace apart from config.** A directory under `$STATE_DIRECTORY`
  that holds neither config nor secrets, so the sandbox can leave those out.
- **Test that it refuses.** Ask the agent to read its own config file. Anything
  but a permission error means its commands run unconfined.
- **Bake in the tools it runs.** Its commands inherit the profile: no `apt`, no
  `sudo`, nothing writable outside the state directory and `/tmp`.
- **JITs need `MemoryDenyWriteExecute=no`**: WASM plugins, Node, Chromium. That
  loosens the profile for the whole unit, so add it in a drop-in only if the
  feature is needed.

## What the profile does not stop

Egress is open (add `IPAddressDeny=any` and `IPAddressAllow=localhost ...` in a
drop-in if that matters, but keep `localhost`, which the proxy connects over).
The service can read `/usr` and world-readable `/etc`. It can connect to any
Unix socket its UID may open, and to abstract-namespace sockets, which have no
permissions to check. Only the system bus is closed. It can connect to anything
listening on loopback except, on the Shelley variants, Shelley's port 9999
([`image/shelley-guard.nft`](../image/shelley-guard.nft), on the VM
`/etc/shelley-guard.nft`, says why). It owns its own state and credentials. It
can fill the disk, and then only the ext4 root reserve, which root alone can
use, keeps journald and `sudo` working. Setup scripts, other units and SSH
sessions run without the profile. No Docker: its daemon is root-equivalent.