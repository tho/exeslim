# exeslim

A minimal [exe.dev](https://exe.dev) base image:
[`exeuntu`](https://github.com/boldsoftware/exeuntu) without the agent
workstation, for a VM that needs no toolchain on the box: a service, a Shelley
VM, a scratch box.

```sh
ssh exe.dev new --name=my-service --image=ghcr.io/tho/exeslim:<build-id>
```

Take `<build-id>` from the
[package page](https://github.com/tho/exeslim/pkgs/container/exeslim), such as
`2026-07-26.20.1`. `:latest` works too, but exe.dev caches it for up to an hour
([tags](#tags)).

## What is in it

exeslim keeps what makes a VM an exe.dev VM: systemd as PID 1, the `exedev`
user, the setup script unit and the growable root filesystem. Plain
`ubuntu:24.04` boots on exe.dev too, but has none of these.

It drops exeuntu's agents, compilers, Python, Node.js, Go, Git, Docker, nginx
and editors, about 3.2 GB per VM, and installs only `ca-certificates`, `curl`,
`iproute2`, `sudo`, `tzdata` and `locales` on top. `apt` works for anything
else, and a Git installed that way takes the VM's
[exe.dev git identity](https://exe.dev/docs/git-identity).

Every `svc-<app>.service`, installed on the VM or by a derived image, runs under
a systemd hardening profile ([deploying](docs/deploying.md)). A unit with any
other name runs unhardened.

## Shelley

`ghcr.io/tho/exeslim:<build-id>-shelley` starts Shelley on boot, with exeuntu's
socket-activated units and exe.dev's installation label, and adds jq, sqlite3
and lsof for its built-in skills. `<build-id>-shelley-full` also adds headless
Chrome, ffmpeg, ImageMagick and Git for its browser, voice, video and git
features (about 1.4 GB). Neither adds compilers. Port 9999 is Shelley's, so do
not bind a service to it.

Shelley acts as `exedev`, who has passwordless sudo, for any local process that
connects to its port, so both variants refuse connections to it from
`svc-<app>` units ([`image/shelley-guard.nft`](image/shelley-guard.nft)).
Anything else on the VM can still reach Shelley.

## Tags

Each build publishes its build id, `:<date>.<run>.<attempt>`, and `:latest`,
with `-shelley` and `-shelley-full` suffixes for the variants. Only the build
id is immutable, and exe.dev caches `:latest` for up to an hour, so pin the
build id or a digest (`ghcr.io/tho/exeslim@sha256:<digest>`) where one build
matters: a derived image's `BASE`, or testing a change pushed minutes ago. An
image's commit is in its `org.opencontainers.image.revision` label. The
[`examples/hello`](examples/hello) service is published as
`ghcr.io/tho/exeslim-hello`.

The package is public. A private fork or derived image needs a classic personal
access token with `read:packages`: `--registry-auth="<you>:$GHCR_TOKEN"`.

## Operating notes

- **Locale.** Only `en_US.UTF-8` (the default) and `en_GB.UTF-8` are
  generated. Add others to `locale-gen` in the Dockerfile. Override per VM
  with `new --env LANG=...` or on the box with `sudo update-locale`. An SSH
  session inherits the client's `LANG`.
- **Setup scripts run on every boot**, as on exeuntu: exe.dev rewrites
  `/exe.dev/setup` at each boot, and `exe-setup.service` runs it as `exedev`
  with the VM's `--env` variables, then removes it. The stored script cannot
  be edited after `new`, so make it idempotent
  (`id -u app >/dev/null 2>&1 || sudo useradd --system app`). It is not ordered
  before `svc-*` units.
- **Patching.** Nothing on the VM patches itself, as on exeuntu: the
  `apt-daily` timers are masked and `unattended-upgrades` is not installed. The
  weekly rebuild (Mondays 04:00 UTC, with a `dist-upgrade`) gives a new VM a
  patched start. Patch an existing VM with `sudo apt-get dist-upgrade`, and a
  derived image by rebuilding it on a newer build id. exe.dev supplies the
  kernel.

## Docs

- [Deploying](docs/deploying.md): writing a hardened `svc-<app>` unit,
  installing it on a VM or in a derived image, secrets, CI checks, failures.
- [Developing](docs/developing.md): working on this repository, merging
  exeuntu, validating the hardening profile.

## Licence

[Apache 2.0](LICENSE), as exeuntu, whose history and files this repository
carries. The built image is Ubuntu packages under their own licences.
