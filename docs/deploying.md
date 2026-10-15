# Deploying a service on exeslim

How to run one service on an exeslim VM under the hardening profile the base
image ships. For tags, setup scripts and patching, see
[operating.md](operating.md); for how the profile was validated, see
[internals.md](internals.md#validating-the-hardening-profile).

## Deployment model

One service per VM. Its binary, unit and any config ship in an image derived
from exeslim (`FROM ghcr.io/tho/exeslim`), all owned by root, so the
service can read them but never change them. Its state lives in exactly one
directory, `/var/lib/<app>`, which systemd creates from `StateDirectory=`.
Nothing else on the VM belongs to the service.

That layout gives two ways to update (see [Updating](#updating)) and makes
moving a service to another VM a copy of one directory.

## Writing the unit

Two complete examples, each a Go program, a unit and a Dockerfile:

- [`examples/hello`](../examples/hello): stateless, one HTTP handler.
- [`examples/counter`](../examples/counter): keeps state and reads a secret.

The derived Dockerfile builds a static binary in a `golang` stage, then copies
the binary and unit into exeslim and enables the unit:

```dockerfile
ARG BASE=ghcr.io/tho/exeslim:latest

FROM golang:1.27 AS build
WORKDIR /src
COPY go.mod main.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /hello

FROM ${BASE}
COPY --from=build --chmod=0755 /hello /usr/local/bin/hello
COPY --chmod=0644 svc-hello.service /etc/systemd/system/svc-hello.service
RUN systemctl enable svc-hello.service
```

Pin `BASE` to a build id or digest for reproducible builds
([picking a tag](operating.md#picking-a-tag)).

The `counter` unit declares only what the app needs:

```ini
[Unit]
Description=counter example service

[Service]
ExecStart=/usr/local/bin/counter
StateDirectory=counter
LoadCredential=token:/etc/counter/token

[Install]
WantedBy=multi-user.target
```

The rules:

- **Name it `svc-<app>.service`.** The profile is a prefix drop-in,
  `/etc/systemd/system/svc-.service.d/50-hardening.conf`, and systemd applies
  it only to units whose name starts with `svc-`. Any other name runs with no
  hardening at all, and nothing warns you.
- **No `User=` and no hardening settings.** The drop-in supplies them; see
  [footguns](#footguns) for what goes wrong when the unit sets them too.
- **Listen on `127.0.0.1:8000`.** exe.dev's proxy defaults to port 8000 on this
  image and connects from inside the VM, so loopback is enough. Then nothing on
  the network interface can reach the service, even with UFW off. `0.0.0.0`
  works too but exposes more.
- **State goes in `StateDirectory=<app>`.** systemd passes the path in
  `$STATE_DIRECTORY`. Under the profile's `DynamicUser=`, the real directory is
  `/var/lib/private/<app>`, reached through a `/var/lib/<app>` symlink, and is
  owned by the service's UID. The rest of the filesystem is read-only to the
  service apart from a private `/tmp`, which is emptied when the unit stops.
- **Secrets come from `LoadCredential=`**, never from the image or
  `Environment=`; see [Secrets](#secrets).

### Secrets

Put the secret in a root-only file on the VM after creating it with `new`, and
point `LoadCredential=` at it. Never put it in the image: anyone who can pull
an image can read every file in it. `Environment=` is no better: any user
on the box can read it with `systemctl show`.

```sh
ssh <vm>.exe.xyz 'sudo install -d -m 0700 /etc/counter && sudo install -m 0600 /dev/stdin /etc/counter/token' <token
ssh <vm>.exe.xyz sudo systemctl restart svc-counter
```

systemd copies the file into a directory only the service can read and passes
its path as `$CREDENTIALS_DIRECTORY`; the app reads
`$CREDENTIALS_DIRECTORY/token`. Until the file exists the unit fails to start
with `243/CREDENTIALS`, which is the expected state of a fresh VM.

This is delivery isolation, not encryption: exe.dev VMs have no TPM, so
nothing is sealed, and root on the VM can read the file. What it buys is that
the service's own UID cannot read `/etc/counter`, and no other service can
read its credential directory.

## First deploy

Build and push the derived image, then create the VM from it:

```sh
ssh exe.dev new --name=my-service --image=ghcr.io/you/my-service:<tag>
```

Provision any [secrets](#secrets), then confirm the unit is running:

```sh
ssh <vm>.exe.xyz systemctl status svc-<app>
```

and open `https://<vm>.exe.xyz/` to see the app through exe.dev's proxy.

## What the profile does

The drop-in is [`image/svc-hardening.conf`](../image/svc-hardening.conf), with
each setting commented. In short:

| Setting | Effect |
|---|---|
| `DynamicUser=yes` | A fresh UID per unit with no shell, home or groups, so code execution in the app is not code execution as `exedev`, who has passwordless sudo. |
| `ProtectSystem=strict`, `PrivateTmp=yes` | Read-only except the state directory and a private `/tmp`, which is disk-backed, not RAM. |
| `ProtectHome=yes` | No reading `exedev`'s keys or dotfiles. |
| `PrivateDevices=yes` | No raw-disk reads through `/dev/vda`. |
| `NoNewPrivileges=yes`, empty `CapabilityBoundingSet=` and `AmbientCapabilities=` | No capabilities, not even through setuid binaries. |
| `RestrictAddressFamilies=AF_INET AF_INET6` | TCP and UDP only. No Unix sockets: no dbus, systemd, tailscaled or container runtime sockets. |
| `RestrictNamespaces=yes`, `ProtectKernelTunables=` and the other `Protect*` keys, `ProtectProc=invisible`, `ProcSubset=pid` | No mounts or user namespaces, no kernel tunables, and other processes are invisible. |
| `SystemCallFilter=@system-service ~@privileged @resources`, `SystemCallErrorNumber=EPERM` | Privileged and resource-control syscalls are blocked; a blocked call fails with `EPERM`, which shows up in the app's log, rather than killing it. |
| `LockPersonality=`, `RestrictRealtime=`, `MemoryDenyWriteExecute=`, `UMask=0077` | No writable and executable memory (fine for Go, breaks JITs); files private by default. |
| `MemoryMax=80%`, `TasksMax=512`, `CPUWeight=50` | A runaway service cannot starve sshd and journald. Percentages are of the VM, hence one service per VM. |
| `Restart=on-failure`, `RestartSec=2s` | Restarts after a crash or OOM kill. The base image sets `DefaultOOMPolicy=continue`, so an OOM kill takes the process, not the unit. |

`systemd-analyze security` rates a unit under the profile at exposure 1.2 and
the same unit without it at 9.4 (on a scale where 0 is most secure and 10
least).

### What it does not stop

- **Egress is open.** The service can connect anywhere. Whatever it can read
  (its own state and credentials) it can send out. If that matters, add
  `IPAddressDeny=any` and `IPAddressAllow=` in a drop-in of your own;
  `svc-check` still passes when you tighten keys the profile does not set.
- **Reading the rest of the filesystem.** `/usr` and world-readable files in
  `/etc` stay readable. Keep secrets in root-only files.
- **Its own data.** A compromised app owns its state directory and its
  credentials; the profile protects the rest of the VM from it, not it from
  itself.
- **Filling the disk.** There is no quota on state or `/tmp`. The only safeguard
  is the ext4 reserve on the root filesystem (about 4.5% on the exe.dev VMs
  checked), which only root can use, so journald, apt and your SSH session keep
  working when the service fills the disk. The
  [probe](internals.md#validating-the-hardening-profile) checks that the
  reserve exists.
- **Kernel bugs.** The syscall filter and namespace ban narrow the kernel
  attack surface; they do not remove it.
- **Anything that is not an `svc-*` unit.** Setup scripts, other units and
  your own SSH sessions run without the profile.

## Footguns

- **A unit not named `svc-*`** runs unhardened, silently.
- **Settings in the unit file.** Drop-ins are read after the unit file, so the
  profile wins for single-value keys: `Restart=always` in the unit becomes
  `on-failure`. List keys merge instead, so `RestrictAddressFamilies=AF_UNIX`
  in the unit file *widens* the profile. And the profile sets no `User=`: a
  `User=exedev` in the unit file names an existing user, which `DynamicUser=`
  then uses as is, so the service runs as `exedev`.
- **Deliberate loosening** goes in your own drop-in that sorts after the
  profile, such as `/etc/systemd/system/svc-<app>.service.d/60-unix.conf`.
  `svc-check` then fails by design; replace it with your own assertion for
  that image.
- **Writes outside the state directory fail with `EROFS`.** That is the
  profile working. Point the app at `$STATE_DIRECTORY` rather than loosening the
  profile.
- **No Unix sockets** means connecting to a local Postgres over `127.0.0.1`, not
  its socket, and logging to stdout (journald captures it), not syslog's
  `/dev/log`.
- **`Restart=on-failure`** does not restart a service that exits 0.
- **`MemoryDenyWriteExecute=`** breaks JIT runtimes. Go has no JIT, so it is
  unaffected.
- **Containers.** No Docker: its daemon is root-equivalent. If you must run a
  container image, add rootless Podman in your derived image and run it outside
  `svc-*` units: the container is its own boundary, and this profile's
  guarantees do not cover it.

## Guarding the profile in CI

Most of the footguns above show up in the unit's effective properties, so
assert on those. The base image ships `svc-check`, which reads what
`systemctl show` reports for your unit and prints every mismatch. In your
derived image's CI:

```sh
docker build -t my-service .
docker run -d --name my-service --privileged --tmpfs /run --tmpfs /run/lock my-service
# Wait for boot. "degraded" is expected: systemd-growfs-root fails in Docker.
until [[ $(docker exec my-service systemctl is-system-running 2>/dev/null) =~ ^(running|degraded)$ ]]; do sleep 1; done
docker exec my-service svc-check svc-my-service.service
```

It asserts that the name starts with `svc-` and the drop-in is applied, that
every setting the profile makes keeps its value, that none of
`ReadWritePaths=`, `BindPaths=`, `BindReadOnlyPaths=` or `SupplementaryGroups=`
is set, that `User=` names no static account such as `exedev` and that no
`Exec*=` command has a privileged `+`, `!` or `!!` prefix.

It is not exhaustive. A setting it does not name, such as a secret in
`Environment=` or an app that ignores its state directory, passes unseen.
`svc-check` ships in the base image with the profile, so your repository needs
no copy of the profile and the check cannot drift from it.

## Updating

**Stateless services:** rebuild and push the image, then replace the VM under
the same name. The service is down while the new VM boots.

```sh
ssh exe.dev rm my-service
ssh exe.dev new --name=my-service --image=ghcr.io/you/my-service:<tag>
```

**Stateful services:** update in place. Copy the binary up, `install` it to a
temporary name beside the old one, then `mv` it over. `mv` within one
filesystem is an atomic rename, so the unit never restarts into a
half-written binary.

```sh
scp counter <vm>.exe.xyz:counter
ssh <vm>.exe.xyz 'sudo install -m 0755 counter /usr/local/bin/.counter.new \
  && sudo mv /usr/local/bin/.counter.new /usr/local/bin/counter \
  && sudo systemctl restart svc-counter'
```

Once updated in place, the VM no longer matches its image exactly, so keep the
Dockerfile in step with what you install. Packages are yours to patch too; see
[keeping a long-lived VM current](operating.md#keeping-a-long-lived-vm-current).

**Moving to a new VM** is a copy of the state directory. Create the new VM
from the same image, provision its [secrets](#secrets), then:

```sh
ssh new.exe.xyz sudo systemctl stop svc-counter
ssh old.exe.xyz 'sudo systemctl stop svc-counter && sudo tar -C /var/lib/private -cf - counter' \
  | ssh new.exe.xyz 'sudo tar -C /var/lib/private -xf - && sudo systemctl start svc-counter'
```

The dynamic UID differs between VMs. That is fine: when systemd starts the
unit and finds the state directory owned by another UID, it chowns it
recursively.
