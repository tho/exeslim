# exeslim

A minimal [exe.dev](https://exe.dev) base image for **deployment targets**: VMs
that run one Go service and are never developed on.

```sh
ssh exe.dev new --name=my-service --image=ghcr.io/tho/exeslim:<build-id>
```

Take `<build-id>` from the
[package page](https://github.com/tho/exeslim/pkgs/container/exeslim). A
build id looks like `2026-07-26.20.1`. `:latest` works too, but exe.dev caches
it for up to an hour ([picking a tag](docs/operating.md#picking-a-tag)).

## Why

exe.dev's stock `exeuntu` image is deliberately a batteries-included agent
workstation. For a VM running a single Go service, that is pure overhead:
exeslim saves **~3.2 GB per VM**. Measurements and the full reasoning are in
[internals](docs/internals.md#why).

## What's in it

`systemd` + `systemd-sysv` + `dbus` + `dbus-user-session`, `ca-certificates`,
`curl`, `iproute2`, `ufw`, `sudo`, `tzdata`, `locales`, and an `exedev` user at
UID 1000 with passwordless sudo, matching exeuntu so existing deploy scripts
keep working.

Deliberately absent: a compiler, Python, Node.js, Go, uv, Git, Docker, nginx,
any editor. If you need those on the box, you want `exeuntu`, not this. `apt`
works, so `sudo apt-get install` is available when something is genuinely
required.

UFW denies all direct inbound traffic; exe.dev's SSH and HTTPS proxy are
unaffected ([why](docs/internals.md#whats-in-it)).

## Docs

- [Deploying](docs/deploying.md): running a service under the hardening profile
  the image ships for `svc-<app>.service` units, first deploy, guarding it in
  CI, updating.
- [Operating](docs/operating.md): picking a tag, registry auth, locales, setup
  scripts, patching.
- [Internals](docs/internals.md): the reasoning and measurements, how it boots,
  correlation with exeuntu, how the image stays current, what was verified on a
  real VM, how the hardening profile was validated.

## Licence

The build recipe in this repository is [MIT](LICENSE). The built image is Ubuntu
packages under their own licences, which MIT does not change.
