# exeslim

A minimal [exe.dev](https://exe.dev) base image:
[`exeuntu`](https://github.com/boldsoftware/exeuntu) without the agent
workstation. For any VM that does not need the toolchain on the box: a service,
a Shelley VM, a scratch box.

```sh
ssh exe.dev new --name=my-service --image=ghcr.io/tho/exeslim:<build-id>
```

Take `<build-id>` from the
[package page](https://github.com/tho/exeslim/pkgs/container/exeslim); it looks
like `2026-07-26.20.1`. `:latest` works too, but exe.dev caches it for up to an
hour ([tags](#tags)).

exeslim drops exeuntu's agents, compilers, Python, Node.js, Go, Git, Docker,
nginx and editors, about 3.2 GB of disk per VM, and keeps what makes a VM an
exe.dev VM: systemd as PID 1, the `exedev` user, the setup script unit, the
growable root filesystem, and Shelley in the variants below. That is the
difference from plain `ubuntu:24.04`, which boots on exe.dev but with none of
it working. On top come `ca-certificates`, `curl`, `iproute2`, `sudo`, `tzdata`
and `locales`; `apt` works for anything else. This repository's history starts
at exeuntu's own commits and the commits after them take things away, so
exeuntu's changes merge in as they land ([developing](docs/developing.md)).

For a VM that runs a service: every `svc-<app>.service` a derived image installs
runs under a systemd hardening profile ([deploying](docs/deploying.md)). A unit
with any other name runs unhardened.

## Shelley

`ghcr.io/tho/exeslim:<build-id>-shelley` sets exe.dev's Shelley installation
label, starts Shelley on boot with exeuntu's socket-activated units, and adds
jq, sqlite3 and lsof for its built-in skills. `<build-id>-shelley-full` also
adds what Shelley's browser, voice, video and git features run: headless Chrome,
ffmpeg, ImageMagick and Git (about 1.4 GB). Neither adds compilers or other
workstation tools. Port 9999 is Shelley's; do not bind a service to it.

Shelley acts as `exedev`, who has passwordless sudo, for any local process
that connects to that port, so the variants refuse connections to it from
`svc-<app>` units ([`image/shelley-guard.nft`](image/shelley-guard.nft)).
Anything else on the VM can still reach Shelley.

## Tags

Each build publishes `:<date>.<run>.<attempt>` (the build id) and `:latest`
for the base, with `-shelley` and `-shelley-full` suffixes for the variants.
Only the build id is immutable; exe.dev caches `:latest` for up to an hour, so
pin the build id or a digest (`ghcr.io/tho/exeslim@sha256:<digest>`) wherever
one specific build matters: a derived image's `BASE`, or testing a change
pushed minutes ago. The commit behind an image is in its
`org.opencontainers.image.revision` label. The hello
example from [`examples/hello`](examples/hello) is published alongside as
`ghcr.io/tho/exeslim-hello`.

The package is public. A private fork or derived image needs a classic personal
access token with `read:packages`:
`--registry-auth="<you>:$GHCR_TOKEN"`.

## Operating notes

- **Locale.** `en_US.UTF-8` (default) and `en_GB.UTF-8` are generated; others
  give setlocale warnings until added to `locale-gen` in the Dockerfile.
  Override per VM with `new --env LANG=...` or on the box with
  `sudo update-locale`. An SSH session inherits the client's `LANG`.
- **Setup scripts run on every boot**, as on exeuntu: exe.dev rewrites
  `/exe.dev/setup` at each boot and `exe-setup.service` runs it as `exedev`,
  with the VM's `--env` variables, then removes it. Make it idempotent
  (`id -u app >/dev/null 2>&1 || sudo useradd --system app`), since there is no
  way to edit the stored script after `new`. It is not ordered before `svc-*`
  units.
- **Patching.** Nothing on the VM patches itself: the `apt-daily` timers are
  masked and `unattended-upgrades` is not installed, matching exeuntu. The
  weekly rebuild (Mondays 04:00 UTC, with a `dist-upgrade`) gives a fresh VM a
  patched start; an existing VM is yours to `apt-get dist-upgrade`, and a derived
  image gets patches when rebuilt on a newer build id. There is no kernel to
  patch; exe.dev supplies it.

## Docs

- [Deploying](docs/deploying.md): writing a hardened `svc-<app>` unit, secrets,
  CI checks, updating.
- [Developing](docs/developing.md): working on this repository, merging
  exeuntu, validating the hardening profile.

## Licence

[Apache 2.0](LICENSE), as exeuntu, whose history and files this repository
carries. The built image is Ubuntu packages under their own licences.
