# exeslim internals

Why exeslim is built the way it is, and the evidence behind it. For running a
VM, see [operating.md](operating.md).

## Why

exe.dev's stock `exeuntu` image is a batteries-included agent workstation:
right for agents, overhead for a VM running a single Go service.

Measured as filesystem usage on real exe.dev VMs, July 2026:

| Image | Disk used |
|---|---|
| `exeuntu`, *after* stripping caches, Go, uv, codex and the mise toolchain | 3,352 MB |
| stock `ubuntu:24.04` | 101 MB |
| **exeslim** | **175 MB** |

**~3.2 GB saved per VM.** exe.dev's Individual (Small) plan pools 100 GB of disk
measured as filesystem usage, so across a handful of service VMs this is the
difference between comfortable and cramped.

## What's in it

The package list and the deliberately absent list are in the
[README](../README.md#whats-in-it). Why some components are there, or not:

**`iproute2`** earns its ~1 MB. When a unit is `active` but the HTTPS proxy
returns nothing, `ss -tlnp` shows in a single command whether anything is
listening on the port the proxy uses, and which process owns it. On a box with no toolchain that is the difference between seeing and
guessing.

**Firewall:** UFW is enabled at VM boot and denies *all* direct inbound network
traffic; outbound traffic is allowed. No port is opened, not even 22 or 8000:
for both SSH and the reverse HTTP proxy to any port, exe.dev reaches the VM
over a VSOCK channel to its `exe-init` guest agent (a hypervisor socket, not the
network interface), so its traffic never touches this policy. These rules only
stop something reaching the VM over its *real* network interface, bypassing
exe.dev's proxy entirely; if a deployment genuinely needs that, add a UFW allow
rule in its idempotent setup script.

**`openssh-server` is absent on purpose.** exe.dev injects its own static `sshd`,
`sftp-server` and `sh` at `/exe.dev/bin`, so SSH works without it, as verified
against a stock `ubuntu:24.04` VM.

**Agent context is carried over** even though no agent ships here, since one may
be installed later and it costs ~1 KB. `image/agent-context.md` lands at the XDG
path Shelley reads, with `~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md` and `~/.pi/AGENTS.md`
symlinked to it: the same layout as exeuntu. It carries exeuntu's platform
guidance plus a note that this box has no toolchain, so an agent doesn't waste a
turn discovering there's no compiler. Want Shelley (and `new --prompt`) on these
VMs? Uncomment `LABEL exe.dev/install-shelley=true` in the Dockerfile.

**The service hardening profile** is exeslim's own, with no exeuntu
counterpart: a prefix drop-in, `/etc/systemd/system/svc-.service.d/50-hardening.conf`,
that hardens every `svc-<app>.service` a derived image installs, and
`/usr/local/bin/svc-check` to assert it in CI. The base image ships no such
unit, so on its own the drop-in changes nothing. What it does and what it does
not stop are in [deploying.md](deploying.md#what-the-profile-does); how it was
validated on a real VM is in
[Validating the hardening profile](#validating-the-hardening-profile).

## How it boots

exe.dev runs the image's `Cmd` as PID 1. `/usr/local/bin/init` mirrors exeuntu's
own wrapper: create `/run/systemd`, mount cgroup2 if absent, remount `/proc/sys`
rw, apply the network-namespace-safe redirect/source-route baseline with
guards, set `ip_unprivileged_port_start=0` so unprivileged services can bind
low ports, then `exec /sbin/init`.

It does the remount before the sysctl writes, unlike exeuntu; the comment in
[`init`](../init) says why.

Without that wrapper you get exe.dev's fallback (`/exe.dev/etc/init-style` reads
`metadata`), which runs the image `Cmd` under `exe-init`: a bare PID 1 with no
service supervision at all. Since every service here is a systemd unit, systemd
is required.

## Correlation with exeuntu

This image was diffed line by line against exeuntu's Dockerfile. Everything
below is platform wiring that exe.dev depends on, and is reproduced here:

| Platform requirement | Why it matters |
|---|---|
| `/etc/fstab` with `x-systemd.growfs` on `/dev/vda` | Without it `systemd-growfs@-.service` never runs, so `--disk=50GB` or `resize` boots with an **unexpanded root filesystem**. `/dev/vda` confirmed as the real root device on live VMs. |
| `exe-setup.service` | Runs `/exe.dev/setup` on every boot, not only the first. Without it `new --setup-script` is accepted and silently does nothing. |
| `CMD` file named exactly `init` | exe.dev's exetini decides a wrapper is an init *from the basename*, and execs rather than forks it. |
| `EXPOSE 8000` | Sets the default proxy port. With no `EXPOSE`, exe.dev defaults to `:80`. |
| `LABEL exe.dev/login-user=exedev` | Which user SSH lands as. |
| systemd mask/disable list | Units that hang or fight the platform in a container-as-VM: resolved, udev, the `-.mount` / `etc-*.mount` set, firstboot, apt-daily. `ssh.service`/`ssh.socket` are masked because exe.dev supplies its own sshd. `systemd-logind` is disabled but *not* masked, matching exeuntu, because it helps populate the XDG runtime directory sockets. |
| `DefaultOOMPolicy=continue` + `SystemCallArchitectures=native` | Container-appropriate manager defaults. |
| guarded network sysctl writes in `init` | Disables accepting IPv4/IPv6 ICMP redirects and IPv4 source-routed packets, and disables sending IPv4 ICMP redirects. |
| UFW boot policy | Denies all direct inbound network traffic, outbound allowed; see **Firewall** in [What's in it](#whats-in-it). |
| `Storage=persistent` journald | `journalctl -u` is the main debugging surface on a box with no toolchain. |
| `/etc/tmpfiles.d/tmp.conf` | Stops systemd wiping `/tmp` at boot, which would race services that use `/tmp` during boot. |
| `rm /usr/sbin/policy-rc.d` | Otherwise apt-installed services silently fail to start. |
| exedev UID 1000 via `usermod -l` | Renames the stock `ubuntu` user so UID, GID, home and subuid line up with exeuntu. |
| linger + `XDG_RUNTIME_DIR` | Populates `/run/user/1000` so `systemd --user` works. |
| Empty `/etc/machine-id` at the end of the build | Package configuration bakes an ID into the image, so every VM would share one identity. Emptied, not removed: an absent file makes systemd treat boot as first boot and re-enable the units disabled above. |

Deliberately **not** carried over: Chrome/headless-shell, the Claude/Codex/pi
agent *binaries*, the pi extension and catalog, nginx + its index page,
xterm-ghostty terminfo, `EXPOSE 9999` (Shelley), `EXEUNTU=1`, and the whole
`unminimize` + man-pages + `locales-all` restoration. The agents' *context*
files are kept; see [What's in it](#whats-in-it).

## How the image stays current

Dependabot keeps the GitHub Actions and the base image digest current
(`.github/dependabot.yml`). Ubuntu major/minor bumps are deliberately ignored
so the image stays on 24.04 LTS. Moving to the next LTS remains a human
decision.

Dependency PRs build without publishing: the workflow runs on `pull_request`
but only pushes tags from `main`. A digest bump or a major Actions bump
therefore gets validated before it can reach `:latest`.

## Verified on a real VM

Booted with `--disk=15GB`, an `--env` override and a setup script that
installed a package and registered a systemd unit: the root filesystem grew to
15G, 0 failed units, the setup
script ran (and runs again on every boot,
[why](operating.md#setup-scripts-run-on-every-boot)), `--env` applied, the
HTTPS proxy served the app over the public URL, the agent context was readable
and `ss` listed listeners with their owning processes.

The proxy reaches loopback. A server bound only to `127.0.0.1:8000` was served
over the VM's HTTPS URL, and its log showed the requests arriving from
`127.0.0.1` (2026-10-11, on an exeuntu VM; the proxy path is the platform's, not
the image's).

`apt-get update`, `apt-get install` and creating a systemd unit from scratch all
work on the running VM, which also confirms the `policy-rc.d` removal.

## Validating the hardening profile

**CI** runs on every build, before anything is published (see
`.github/workflows/build.yml`): `systemd-analyze verify` and
`systemd-analyze security --offline=true --threshold=20` on
[`probe/svc-probe.service`](../probe/svc-probe.service) and both example units
inside the built image; then it builds both examples on that image, boots each
under Docker, runs `svc-check`, and requests `hello` on :8000.

**The probe** checks what CI cannot: that the profile holds on a real exe.dev
VM, from inside the service. Run it by hand whenever the drop-in changes.
[`probe/main.go`](../probe/main.go) is a static Go program that logs one PASS
or FAIL line per check, then a summary, then serves the same report on :8000.
It checks that:

- it is not root, has no extra groups, holds no capabilities, has `NoNewPrivs`
  and runs under the profile's seccomp filters;
- writes to its own binary, `/etc` and `/usr` fail with `EROFS` while writes to
  its state directory and `/tmp` succeed;
- `/tmp` is not tmpfs;
- `/dev/vda` does not exist and `/home` cannot be listed;
- Unix sockets, mounts and user namespaces are denied;
- outbound HTTPS with certificate verification works;
- the root filesystem keeps a root-only reserve.

A denial check passes only on the profile's own error, so a plain unprivileged
user, refused by ordinary permissions instead, still fails it.

Any exe.dev VM with systemd 255 will do, exeslim or not; the steps install the
drop-in under test over whatever is there:

```sh
(cd probe && CGO_ENABLED=0 go build)
scp probe/svc-probe probe/svc-probe.service image/svc-hardening.conf <vm>.exe.xyz:
ssh <vm>.exe.xyz
sudo install -D -m 0644 svc-hardening.conf /etc/systemd/system/svc-.service.d/50-hardening.conf
sudo install -m 0755 svc-probe /usr/local/bin/svc-probe
sudo install -m 0644 svc-probe.service /etc/systemd/system/svc-probe.service
sudo systemctl daemon-reload && sudo systemctl start svc-probe
journalctl -u svc-probe -o cat    # every line PASS, then "SUMMARY 16 checks, 0 FAIL"
curl -s localhost:8000            # same report
sudo systemctl stop svc-probe
# Negative control: outside the unit, most checks must FAIL.
(cd / && sudo -u nobody timeout 10 /usr/local/bin/svc-probe)
```

Then check proxy reachability, which the probe cannot do itself because
exe.dev's proxy requires an exe.dev login: start the unit again, open
`https://<vm>.exe.xyz:8000/` in a browser while logged in to exe.dev, and
expect the same report. The proxy forwards ports 3000 to 9999 to users with
access to the VM ([proxy docs](https://exe.dev/docs/proxy.md)).

Then remove the probe:

```sh
sudo systemctl stop svc-probe
sudo rm -r /usr/local/bin/svc-probe /etc/systemd/system/svc-probe.service \
  /var/lib/svc-probe /var/lib/private/svc-probe
sudo rmdir /var/lib/private 2>/dev/null    # only if the probe created it
sudo systemctl daemon-reload
```

On a VM that is not exeslim, also `sudo rm -r /etc/systemd/system/svc-.service.d`.
On an exeslim VM that directory belongs to the image, so the test copy of the
drop-in stays until the VM is recreated: use a VM you can throw away.

Last run on 2026-10-11, on an exe.dev VM with kernel 6.12.93 and systemd
255.4: 16 of 16 PASS under the profile; 9 FAIL as `nobody` outside it (the
privileges check, every denial except mount, and the state directory write).
Proxy reachability was not checked on that run.
