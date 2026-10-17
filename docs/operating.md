# Operating exeslim

Creating, configuring and patching exeslim VMs. For running a service on one,
see [deploying.md](deploying.md); for why the image is built this way, see
[internals.md](internals.md).

## Picking a tag

Each build publishes four tags for the default variant. Only one is immutable:

| Tag | Moves? | Cached |
|---|---|---|
| `:latest` | yes, every build | 1 h |
| `:<date>` | yes, two builds on the same day overwrite it | 24 h |
| `:<sha>` | yes, the scheduled rebuild reuses the same commit | 24 h |
| **`:<date>.<run>.<attempt>`** (the *build id*) | **no** | 24 h, moot |

Cache times are exe.dev's: 1 h for `latest`, `main` and `master`, 24 h for
every other tag.

Pin the build id or digest wherever you need one specific build: a derived
image's `BASE`, a VM that must match one that already exists, or testing a
change you pushed minutes ago. `:latest` is fine for a VM you are trying out,
as long as it can be up to an hour stale.

A build id looks like `2026-07-26.20.1`. The current list is on the
[package page](https://github.com/tho/exeslim/pkgs/container/exeslim).

```sh
ssh exe.dev new --name=my-service --image=ghcr.io/tho/exeslim:<build-id>
```

Each build also publishes the [hello example](deploying.md#writing-the-unit) as
`ghcr.io/tho/exeslim-hello`, tagged `:latest` and the same build id.

Or the digest, immutable by construction:

```sh
ssh exe.dev new --name=my-service \
  --image=ghcr.io/tho/exeslim@sha256:<digest>
```

Two Shelley-enabled variants use the same `ghcr.io/tho/exeslim` repository,
with a suffix on version tags:

| Default variant | Shelley variant | Shelley full variant |
|---|---|---|
| `:latest` | `:latest-shelley` | `:latest-shelley-full` |
| `:<date>` | `:<date>-shelley` | `:<date>-shelley-full` |
| `:<sha>` | `:<sha>-shelley` | `:<sha>-shelley-full` |
| `:<date>.<run>.<attempt>` | `:<date>.<run>.<attempt>-shelley` | `:<date>.<run>.<attempt>-shelley-full` |

All variants use the same build id. Only the build-id tags are immutable;
exe.dev caches all Shelley tags, including `:latest-shelley`, for 24 hours.
Both Shelley variants add the
[documented installation label](https://exe.dev/docs/customization.md#custom-image-properties).
exe.dev installs the Shelley binary when creating the VM; the label alone does
not start it, so both also ship exeuntu's socket-activated `shelley.socket`
and `shelley.service` units, plus jq and sqlite3 (built-in skills) and lsof.
The application port remains 8000, but 9999 is Shelley's, so do not bind a
service to it.

`-shelley` stops there, so Shelley's browser, voice and video transcription,
HEIC uploads and Git views fail for lack of their tools. `-shelley-full` adds
those tools, which is why it is about 1.4 GB rather than 270 MB: headless
Chrome at `/headless-shell` (browser tool, screenshots, screencasts), ffmpeg
and ffprobe (voice and video recordings, screencasts), ImageMagick with libheif
(HEIC/AVIF uploads) and Git (diffs, commit tours, worktrees).
`Dockerfile.shelley-full` maps each package to the feature that needs it. Neither variant adds compilers or other workstation
tools.

```sh
ssh exe.dev new --name=my-service --image=ghcr.io/tho/exeslim:<build-id>-shelley
```

exe.dev's SSH command parser splits arguments on spaces, so anything
containing a space needs nested quoting: `--comment='"a b c"'`. Without it the
text is parsed as positional arguments and `new` fails.

## Private forks: registry auth

The package is public, so no `--registry-auth` is needed. If you fork this
repository and keep the package private, or push a private derived image, pass
a [classic personal access
token](https://github.com/settings/tokens/new?scopes=read:packages&description=exe.dev%20ghcr%20pull)
with `read:packages`. Read it from a variable so it stays out of your shell
history:

```sh
ssh exe.dev new --name=my-service \
  --image=ghcr.io/<you>/exeslim:<build-id> \
  --registry-auth="<you>:$GHCR_TOKEN"
```

## Locales

`en_US.UTF-8` (default) and `en_GB.UTF-8` are generated; exeuntu's
`locales-all` is ~200 MB for the same job. Override the locale per VM with
`new --env LANG=en_GB.UTF-8` or on the box with `sudo update-locale`. Per
session there is nothing to do: macOS forwards `LANG` over SSH via `SendEnv`,
so an interactive login already inherits the client's locale. Any other locale
produces setlocale warnings; to use one, add it to `locale-gen` in the
Dockerfile.

## Setup scripts run on every boot

A `--setup-script` must be idempotent. On every boot, exe.dev rewrites
`/exe.dev/setup` with the script captured at `new`, and `exe-setup.service`
runs it again. The stock exeuntu image behaves the same way.

The script runs as `exedev`, so privileged steps need `sudo`. It is not ordered
before `svc-*` units, so do not use it for anything a service needs at start,
such as its config or secrets: the service may start first.

A script that is not idempotent fails on the second boot and every boot after,
leaves `exe-setup.service` in `failed`, and keeps `systemctl --failed` from
ever being clean again. Seen on a real VM: a bare `useradd --system` succeeded
on the first boot and exited 9 (`user already exists`) on the second.

Guard anything that cannot run twice:

```sh
id -u myapp >/dev/null 2>&1 || sudo useradd --system --user-group myapp
```

The guard has to be in the script when the VM is created. There is no way to
view, edit or clear the stored script after `new`, and editing `/exe.dev/setup`
on the box is undone at the next boot. On a VM that is already failing, disable
`exe-setup.service`, run `systemctl reset-failed` after every reboot, or rebuild
the VM.

## Patching

Nothing on the VM patches itself. This image masks `apt-daily.timer`,
`apt-daily-upgrade.timer` and `unattended-upgrades.service` (mirroring exeuntu),
and `unattended-upgrades` is not installed at all. Whether a box that exists to
run one service should reboot-and-upgrade on its own is a decision for whoever
owns that service, not for the base image.

The weekly rebuild (Mondays, 04:00 UTC, see
[`build.yml`](../.github/workflows/build.yml); it runs a `dist-upgrade`, see the
[Dockerfile](../Dockerfile)) gives a *fresh* VM a patched start. That is all it
does: there is no way to swap the image under a live VM, so once a VM exists its
packages are yours to maintain. Replacing it with a fresh one works, but it is a
redeploy you choose, not an upgrade path the platform gives you. A derived image
gets the patches only when you rebuild it on a newer build id
([updating](deploying.md#updating)).

There is no kernel to patch. exe.dev supplies it (`uname -r` reports 6.12.x
rather than Noble's 6.8), and no `linux-image` package is installed, so
`/var/run/reboot-required` never shows up from a kernel update. A restart is
only needed to move long-running processes onto a patched libc or openssl:
restart the unit, or `ssh exe.dev restart <vm>`.

### Keeping a long-lived VM current

By hand:

```sh
sudo apt-get update && sudo apt-get dist-upgrade
```

Or opt in to unattended upgrades. **Unmask before installing**: dpkg cannot
enable a masked unit, so installing first leaves all three units masked with
`Failed to enable unit: ... is masked` buried in the apt output:

```sh
sudo systemctl unmask apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service
sudo apt-get update && sudo apt-get install -y unattended-upgrades
sudo systemctl start apt-daily.timer apt-daily-upgrade.timer
```

That last line is not redundant. Installing the package *enables* both timers
but leaves them inactive in the running system: `systemctl list-timers` shows
them with no next elapse until they are started or the VM is restarted.
Enabled but inactive timers look exactly like working automatic patching while
doing nothing. Confirm the timers are armed:

```sh
systemctl list-timers 'apt-daily*'
sudo unattended-upgrade --dry-run --verbose
```

The stock allowed origins are `noble` and `noble-security`, which is the right
default for a deployment target: security fixes, no surprise version jumps.
