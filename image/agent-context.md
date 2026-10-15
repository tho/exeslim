You are running in an exe.dev VM.

https://exe.dev/docs/proxy.md has details about the exe.dev HTTPS proxy.

Only use documented exe.dev features (see https://exe.dev/docs.md). Undocumented local endpoints are internal infrastructure: unstable and unsupported.

## This VM runs exeslim, not exeuntu

It is a deployment target: a minimal base carrying systemd, TLS roots, curl,
`ss` (iproute2), sudo and ufw, and little else. Do not assume the usual
exeuntu toolbox is present.

**Not installed:** compiler (`build-essential`), Python, Node.js, Go, uv, Git,
Docker, nginx, Chrome. `apt` works, so `sudo apt-get install <pkg>` is fine for
anything you genuinely need, but prefer building artifacts elsewhere and
shipping them here, which is how this box is meant to be used.

**Services are systemd units.** Start/stop with `systemctl`, and read logs with
`journalctl -u <name>`; journald storage is persistent, and with no toolchain
on the box it is the main debugging surface. `ss -tlnp` shows what is
listening.

**The app is a prebuilt binary** shipped in an image derived from exeslim, or
updated in place by `scp` and a restart. Anything you install directly on the
VM is lost if it is recreated from a fresh image, so durable changes belong in
the deploying repo, not on this VM.

**The app's unit is hardened only if named `svc-<app>.service`.** The drop-in
`/etc/systemd/system/svc-.service.d/50-hardening.conf` applies to every unit
whose name starts with `svc-`: a dynamic UID, read-only filesystem except
`StateDirectory=`, no Unix sockets, no capabilities. A unit with any other name
runs unhardened. Rules:

- Do not add `User=` or loosen these settings to make something work.
- Write only to `$STATE_DIRECTORY`.
- Connect to local databases over TCP at `127.0.0.1`, not a Unix socket.
- Listen on `127.0.0.1:8000`, the proxy's default port. UFW denies direct
  inbound traffic and the proxy does not need it opened; do not open ports.
- Secrets go in a root-only file read through `LoadCredential=`, never in
  `Environment=` or the image.
- Verify with `svc-check svc-<app>.service`. It checks the profile's settings,
  extra writable or bound paths, supplementary groups, static users and
  privileged `+`/`!` command prefixes; it is not exhaustive.

The drop-in and `/usr/local/bin/svc-check` on this VM are the source of truth
for its image. Background, possibly newer than this VM:
https://github.com/tho/exeslim/blob/main/docs/deploying.md
