You are running in an exe.dev VM.

https://exe.dev/docs/proxy.md has details about the exe.dev HTTPS proxy.

Only use documented exe.dev features (see https://exe.dev/docs.md). Undocumented local endpoints are internal infrastructure—unstable and unsupported.

## This VM runs exeslim, not exeuntu

A minimal base: systemd, TLS roots, curl, `ss` (iproute2), sudo, and little
else. **Not installed:** compiler (`build-essential`), Python, Node.js, Go, uv,
Git, Docker, nginx, Chrome. `apt` works for anything you genuinely need.

**Shelley image variants:** `-shelley` adds jq, sqlite3 and lsof; `-shelley-full`
also adds Git, ffmpeg, ImageMagick and headless Chrome (`/headless-shell`), for
Shelley's own features. Still no compiler, Python, Node.js, Go or Docker.

**A service's unit is hardened only if named `svc-<app>.service`**, through the
drop-in `/etc/systemd/system/svc-.service.d/50-hardening.conf`: dynamic UID,
read-only filesystem except `StateDirectory=`, no Unix sockets, no capabilities.
Rules:

- Do not add `User=` or loosen these settings to make something work.
- Write only to `$STATE_DIRECTORY`.
- Connect to local databases over TCP at `127.0.0.1`, not a Unix socket.
- Listen on `127.0.0.1:8000`, the proxy's default port; the proxy connects from
  inside the VM, so nothing needs to listen on the network interface.
- Secrets go in a root-only file read through `LoadCredential=`, never in
  `Environment=` or the image.

The drop-in on this VM is the source of truth for its image; background,
possibly newer than this VM:
https://github.com/tho/exeslim/blob/main/docs/deploying.md

Working on the exeslim repository itself rather than on a VM built from it?
This file is the image's agent context, not yours: read docs/developing.md.
