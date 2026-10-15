# Deploying a service on exeslim

How to run one service on an exeslim VM under the hardening profile the base
image ships. For tags, setup scripts and patching, see
[operating.md](operating.md); for how the profile was validated, see
[internals.md](internals.md#validating-the-hardening-profile).

## Deployment model

One service per VM. Its binary, unit and any config ship in an image derived
from exeslim (`FROM ghcr.io/tho/exeslim`), all owned by root, so the
service can read them but never change them. Its state lives in exactly one
directory, `/var/lib/<app>`, which systemd creates from `StateDirectory=`, and
its secrets in root-only files under `/etc/<app>/`, provisioned on the VM.
Nothing else on the VM belongs to the service.

That layout gives two ways to update (see [Updating](#updating)) and makes
moving a service to another VM a copy of one directory plus provisioning its
secrets again.

## Writing the unit

A complete example (a Go program, a unit and a Dockerfile) is in
[`examples/hello`](../examples/hello): stateless, one HTTP handler. CI
publishes it, built on each exeslim build, as `ghcr.io/tho/exeslim-hello`, so
you can boot it without building anything:

```sh
ssh exe.dev new --name=hello --image=ghcr.io/tho/exeslim-hello:<build-id>
```

The derived Dockerfile builds a static binary in a `golang` stage, then copies
the binary and unit into exeslim and enables the unit:

```dockerfile
ARG BASE=ghcr.io/tho/exeslim:<build-id>

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
([picking a tag](operating.md#picking-a-tag)); `examples/hello` defaults to
`:latest` only so that it always builds. If your Dockerfile runs `apt-get`
after `FROM`, end it with `RUN : >/etc/machine-id`: package configuration can
write a machine ID into the image, and every VM created from it would then
share one.

A unit for a service that keeps state and reads a secret declares only what
the app needs:

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

The rules:

- **Name it `svc-<app>.service`.** The profile is a prefix drop-in,
  `/etc/systemd/system/svc-.service.d/50-hardening.conf`, and systemd applies
  it only to units whose name starts with `svc-`. Any other name runs with no
  hardening at all, and nothing warns you.
- **No `User=` and no hardening settings.** The drop-in supplies them; see
  [footguns](#footguns) for what goes wrong when the unit sets them too.
- **Listen on `127.0.0.1:8000`.** exe.dev's proxy defaults to port 8000 on this
  image and connects from inside the VM, so loopback is enough. That way
  nothing on the network interface can reach the service, even with UFW off.
  `0.0.0.0` works too but exposes more. A service on another port between 3000
  and 9999 is reachable at `https://<vm>.exe.xyz:<port>/` by users with access
  to the VM ([proxy docs](https://exe.dev/docs/proxy.md)).
- **State goes in `StateDirectory=<app>`.** systemd passes the path in
  `$STATE_DIRECTORY`. Under the profile's `DynamicUser=`, the real directory is
  `/var/lib/private/<app>`, reached through a `/var/lib/<app>` symlink, and is
  owned by the service's UID. The rest of the filesystem is read-only to the
  service apart from a private `/tmp`, which is emptied when the unit stops.
- **Secrets come from `LoadCredential=`**, never from the image or
  `Environment=`; see [Secrets](#secrets).

### Secrets

After creating the VM with `new`, put the secret in a root-only file on it and
point `LoadCredential=` at that file. Never put it in the image: anyone who can
pull an image can read every file in it. `Environment=` is no better: any user
on the box can read it with `systemctl show`.

```sh
ssh <vm>.exe.xyz 'sudo install -d -m 0700 /etc/my-service && sudo install -m 0600 /dev/stdin /etc/my-service/token' <token
ssh <vm>.exe.xyz sudo systemctl restart svc-my-service
```

systemd copies the file into a directory only the service can read and passes
its path as `$CREDENTIALS_DIRECTORY`; the app reads
`$CREDENTIALS_DIRECTORY/token`. The file arrives byte for byte, so a trailing
newline in `token` becomes part of the secret: write it with `printf %s` or
trim it in the app. Until the file exists the unit fails to start with
`243/CREDENTIALS`, which is the expected state of a fresh VM.

This is delivery isolation, not encryption: exe.dev VMs have no TPM, so
nothing is sealed, and root on the VM can read the file. What it buys is that
the service's own UID cannot read `/etc/my-service`, and no other service can
read its credential directory.

## Guarding the profile in CI

The base image ships `svc-check` alongside the profile, so the check cannot
drift from it. It reads what `systemctl show` reports for your unit and prints
every mismatch: most of the [footguns](#footguns) show up in the unit's
effective properties. `svc-check` asserts that the name starts with `svc-` and
the drop-in is applied, that every setting the profile makes keeps its value
(`MemoryMax=` only has to be a limit, since 80% resolves differently per VM),
that none of `ReadWritePaths=`, `BindPaths=`, `BindReadOnlyPaths=` or
`SupplementaryGroups=` is set, that neither `User=` nor `Group=` names a static
account such as `exedev`, and that no `Exec*=` command has a privileged `+`,
`!` or `!!` prefix.

A service with a `LoadCredential=` stays down until the credential exists, so
provision a throwaway one first. In Docker, run `mount --make-rshared /` in
the container before that: Docker leaves mounts private, and the credential
directory then never reaches the unit. An exe.dev VM needs neither. In your
derived image's CI:

```sh
docker build --pull -t my-service .
docker run -d --name my-service --privileged --tmpfs /run --tmpfs /run/lock my-service
# Wait for boot. "degraded" is expected: systemd-growfs-root fails in Docker.
timeout 120 bash -c 'until [[ $(docker exec my-service systemctl is-system-running 2>/dev/null) =~ ^(running|degraded)$ ]]; do sleep 1; done'
# Only for a unit with LoadCredential=: share mounts, provision, restart.
docker exec my-service mount --make-rshared /
docker exec my-service bash -c 'install -d -m 0700 /etc/my-service && printf test | install -m 0600 /dev/stdin /etc/my-service/token'
docker exec my-service systemctl restart svc-my-service.service
docker exec my-service svc-check svc-my-service.service
# svc-check reads properties only; this shows the service is up and answering.
docker exec my-service curl -fsS --retry 10 --retry-connrefused --retry-delay 1 http://127.0.0.1:8000/
```

`svc-check` is not exhaustive. Anything it does not check, such as a secret in
`Environment=` or an app that ignores its state directory, passes unseen.

## First deploy

Build and push the derived image, then create the VM from it. Use an immutable
tag or digest: exe.dev caches mutable tags for up to 24 hours
([picking a tag](operating.md#picking-a-tag)). GHCR makes new packages private,
so unless you made yours public, add `--registry-auth`
([registry auth](operating.md#private-forks-registry-auth)).

```sh
ssh exe.dev new --name=my-service --image=ghcr.io/you/my-service:<tag>
```

Provision any [secrets](#secrets), then confirm the unit is running:

```sh
ssh <vm>.exe.xyz systemctl status svc-<app>
```

and open `https://<vm>.exe.xyz/` to see the app through exe.dev's proxy.

## Updating

The weekly exeslim rebuild does not reach your service by itself. To pick up
base image patches, rebuild your derived image on a newer build id (a weekly
CI job works) and deploy it as below.

**Stateless services:** rebuild and push the image under a new tag, then
replace the VM under the same name and provision its [secrets](#secrets)
again: they lived on the old VM, not in the image. The service is down from
the `rm` until the new VM boots with its secrets, and if `new` fails there is
no VM at all. If that is not acceptable, create the new VM under another name,
check it, then remove the old one; the URL follows the name.

```sh
ssh exe.dev rm my-service
ssh exe.dev new --name=my-service --image=ghcr.io/you/my-service:<new-tag>
```

**Stateful services:** update in place. Copy the binary up, `install` it to a
temporary name beside the old one, then `mv` it over. `mv` within one
filesystem is an atomic rename, so the unit never restarts into a
half-written binary.

```sh
scp my-service <vm>.exe.xyz:my-service
ssh <vm>.exe.xyz 'sudo install -m 0755 my-service /usr/local/bin/.my-service.new \
  && sudo mv /usr/local/bin/.my-service.new /usr/local/bin/my-service \
  && sudo systemctl restart svc-my-service'
```

`Restart=` never gives up on a binary that crashes, so to roll back, keep the
old one: `sudo cp -p /usr/local/bin/my-service /usr/local/bin/my-service.prev`
before the `mv`. If the unit file changes too, install it and run
`sudo systemctl daemon-reload` before the restart.

Once updated in place, the VM no longer matches its image exactly, so keep the
Dockerfile in step with what you install. Packages are yours to patch too; see
[keeping a long-lived VM current](operating.md#keeping-a-long-lived-vm-current).

**Moving to a new VM** is a copy of the state directory. Create the new VM
from the same image, provision its [secrets](#secrets), then:

```sh
ssh new.exe.xyz 'sudo systemctl stop svc-my-service && sudo rm -rf /var/lib/private/my-service \
  && sudo install -d -m 0700 /var/lib/private'
ssh old.exe.xyz 'sudo systemctl stop svc-my-service && sudo tar -C /var/lib/private -cf - my-service' \
  | ssh new.exe.xyz 'sudo tar -C /var/lib/private -xf - && sudo systemctl start svc-my-service'
ssh old.exe.xyz sudo systemctl disable svc-my-service
```

The `rm` matters: the new VM's unit has already started once and written fresh
state. Extracting over it leaves behind anything the old tree does not
overwrite, such as a new lock file or an empty database beside the old one.

If the copy fails, the old service is left stopped:
`ssh old.exe.xyz sudo systemctl start svc-my-service` brings it back. Once the
new VM works, `ssh exe.dev rm old`; until then the `disable` keeps the old unit
from starting again on a reboot, so two copies never run on diverged state.

The dynamic UID differs between VMs. That is fine: when systemd starts the
unit and finds the state directory owned by another UID, it chowns it
recursively.

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
| `Restart=on-failure`, `RestartSec=2s`, `RestartSteps=10`, `RestartMaxDelaySec=1min`, `StartLimitIntervalSec=0` | Restarts after a crash or OOM kill, waiting 2s after the first failure and backing off to 1min, and never gives up. An OOM kill of the main process counts as a failure; the base image's `DefaultOOMPolicy=continue` only matters when the kernel kills a child process, which then leaves the rest of the unit running. |

`systemd-analyze security` rates a unit under the profile at exposure 1.2 and
the same unit without it at 9.4 (on a scale where 0 is most secure and 10
least).

### What it does not stop

- **Egress is open.** The service can connect anywhere. Whatever it can read
  (its own state and credentials) it can send out. If that matters, add
  `IPAddressDeny=any` and `IPAddressAllow=localhost <destinations>` in a
  drop-in of your own. Keep `localhost`: the deny list filters inbound traffic
  too, including exe.dev's proxy on loopback. `svc-check` still passes when you
  tighten keys the profile does not set, but it checks the keys the profile
  does set for their exact values, so a lower `TasksMax=` or `CPUWeight=`
  fails it by design.
- **Reading the rest of the filesystem.** `/usr` and world-readable files in
  `/etc` stay readable. Keep secrets in root-only files.
- **Its own data.** A compromised app owns its state directory and its
  credentials; the profile protects the rest of the VM from the app, not the
  app from itself.
- **Filling the disk.** There is no quota on state or `/tmp`. The only safeguard
  is the ext4 reserve on the root filesystem (about 4.5% on the exe.dev VMs
  checked), which only root can use, so journald, apt and anything you run with
  `sudo` keep working when the service fills the disk; as `exedev`, prefix
  recovery commands with `sudo`. The
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
  `svc-check` then fails by design; in that image's CI, replace `svc-check`
  with your own assertion.
- **`systemctl edit` on the VM** writes `override.conf`, which sorts after
  `50-hardening.conf` and so overrides the profile. Nothing checks the VM
  itself, so make changes in the image, where CI runs `svc-check`.
- **Writes outside the state directory fail with `EROFS`.** That is the
  profile working. Point the app at `$STATE_DIRECTORY` rather than loosening the
  profile.
- **No Unix sockets** means connecting to a local Postgres over `127.0.0.1`, not
  its socket, and logging to stdout (journald captures it), not syslog's
  `/dev/log`.
- **`Restart=on-failure`** does not restart a service that exits 0.
- **Containers.** No Docker: its daemon is root-equivalent. If you must run a
  container image, add rootless Podman in your derived image and run it outside
  `svc-*` units: the container is its own boundary, and this profile's
  guarantees do not cover it.
