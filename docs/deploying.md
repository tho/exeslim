# Deploying a service on exeslim

One service per VM. Its binary, unit and config ship in an image derived from
exeslim, root-owned, so the service can read but not change them. Its state
lives in `/var/lib/<app>`, created by `StateDirectory=`, and its secrets in
root-only files under `/etc/<app>/`, provisioned on the VM. Nothing else on the
VM belongs to the service.

## The unit

[`examples/hello`](../examples/hello) is the complete minimal case; CI publishes
it as `ghcr.io/tho/exeslim-hello`. The derived Dockerfile builds a static
binary, copies it and the unit in, and enables the unit:

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

If the Dockerfile runs `apt-get` after `FROM`, end it with
`RUN : >/etc/machine-id`: package configuration can bake a machine ID into the
image, which every VM created from it would then share.

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
- **Listen on `127.0.0.1:8000`.** exe.dev's proxy defaults to port 8000 on this
  image and connects from inside the VM. Other ports between 3000 and 9999 are
  reachable at `https://<vm>.exe.xyz:<port>/` by users with access to the VM.
- **State goes in `StateDirectory=`**, passed as `$STATE_DIRECTORY`. Under
  `DynamicUser=` the real directory is `/var/lib/private/<app>`, reached through
  a `/var/lib/<app>` symlink. The rest of the filesystem is read-only to the
  service (writes fail with `EROFS`) apart from a private `/tmp`, emptied when
  the unit stops.
- **Secrets come from `LoadCredential=`.** After `new`, put the secret in a
  root-only file and restart:

  ```sh
  ssh <vm>.exe.xyz 'sudo install -d -m 0700 /etc/my-service && sudo install -m 0600 /dev/stdin /etc/my-service/token' <token
  ssh <vm>.exe.xyz sudo systemctl restart svc-my-service
  ```

  The app reads `$CREDENTIALS_DIRECTORY/token`, byte for byte (mind a trailing
  newline). Until the file exists the unit fails with `243/CREDENTIALS`, the
  expected state of a fresh VM. Never put secrets in the image or in
  `Environment=`: both are readable by anyone who can pull the image or run
  `systemctl show`.
- **Unix sockets work.** `sd_notify()` reaches systemd, so `Type=notify` and
  `WatchdogSec=` do what they say. A local database is reachable over its
  socket, with peer authentication mapping the service's user, `svc-<app>`
  (resolvable through nss-systemd), to a role. `/dev/log` works too, though
  stdout (journald) is simpler. The system bus is inaccessible.

What the profile sets, and why, is in
[`image/svc-hardening.conf`](../image/svc-hardening.conf), one comment per
setting. `systemd-analyze security` rates a unit under it at exposure 1.2 and
the same unit without it at 9.4.

To loosen a setting on purpose, add a drop-in that sorts after
`50-hardening.conf`, such as `svc-<app>.service.d/60-proc.conf`. Put it in the
image rather than using `systemctl edit` on the VM, which writes an override
the image does not have and CI never sees.

## What the profile does not stop

Egress is open (add `IPAddressDeny=any` and `IPAddressAllow=localhost ...` in a
drop-in if that matters; keep `localhost`, the proxy connects over it). The
service can read `/usr` and world-readable `/etc`. It can connect to any Unix
socket its UID may open, and to abstract-namespace sockets, which have no
permissions to check; only the system bus is closed. It can connect to
anything listening on loopback except, on the Shelley variants, Shelley's port
9999 ([`image/shelley-guard.nft`](../image/shelley-guard.nft) says why). It owns its own state and credentials. It can fill the disk; only the ext4
root reserve, which root alone can use, keeps journald and `sudo` working then.
Setup scripts, other units and SSH sessions run without the profile. No Docker:
its daemon is root-equivalent.

## Checking the profile in CI

`systemd-analyze security` scores the unit's effective settings, 1.2 with the
profile and 9.4 without, so a threshold fails the build on a unit the drop-in
missed and on most loosening, and the output lists what it found. It runs
inside the derived image without booting it:

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

## Deploying and updating

Create the VM from an immutable tag or digest, provision secrets, check
`systemctl status svc-<app>` and open `https://<vm>.exe.xyz/`.

The weekly exeslim rebuild does not reach your service by itself: rebuild the
derived image on a newer build id to pick up base patches.

**Stateless:** replace the VM (`ssh exe.dev rm`, then `new` under the same
name) and provision its secrets again; they lived on the old VM. For no
downtime, create under another name, check, remove the old one.

**Stateful:** update in place. `mv` within one filesystem is atomic, so the unit
never restarts into a half-written binary:

```sh
scp my-service <vm>.exe.xyz:my-service
ssh <vm>.exe.xyz 'sudo install -m 0755 my-service /usr/local/bin/.my-service.new \
  && sudo mv /usr/local/bin/.my-service.new /usr/local/bin/my-service \
  && sudo systemctl restart svc-my-service'
```

Keep the old binary beside it for rollback; `Restart=` never gives up on one
that crashes. If the unit file changes too, `daemon-reload` before the restart.
Moving to another VM is a `tar` of `/var/lib/private/<app>` between stopped
units; the dynamic UID differs per VM, and systemd chowns the directory on start.
