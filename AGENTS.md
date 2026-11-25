You are running in an exe.dev VM (https://exe.dev/docs.md).

## This VM runs exeslim, not exeuntu

A minimal base: systemd, TLS roots, curl, `ss` (iproute2), sudo, and little
else. **Not installed:** compiler (`build-essential`), Python, Node.js, Go, uv,
Git, Docker, nginx, Chrome. `apt` works for anything you genuinely need; an
installed Git takes the VM's exe.dev identity from `/etc/gitconfig`.

**Shelley image variants:** `-shelley` adds jq, sqlite3 and lsof; `-shelley-full`
also adds Git, ffmpeg, ImageMagick and headless Chrome (`/headless-shell`), for
Shelley's own features. Still no compiler, Python, Node.js, Go or Docker.
Both load a firewall rule (`shelley-guard.service`) that keeps `svc-<app>`
units off Shelley's port 9999; leave it in place.

**A service's unit is hardened only if named `svc-<app>.service`**, through the
drop-in `/etc/systemd/system/svc-.service.d/50-hardening.conf`: dynamic UID,
read-only filesystem except `StateDirectory=`, no D-Bus, no capabilities. An
app may still sandbox itself with Landlock or seccomp; test that it is
enforced, since many fall back to running without one. Rules:

- Do not add `User=` or loosen these settings to make something work.
- Write only to `$STATE_DIRECTORY`. `HOME` is unset and `~` is `/`,
  read-only; for an app that writes under `~`, set `StateDirectory=` and start
  it through `/usr/local/bin/svc-exec`, which points `HOME` and the XDG
  directories at the state directory.
- Connect to local databases over their Unix socket with peer authentication
  (the service's user is `svc-<app>`), or over TCP at `127.0.0.1`.
- Listen on `127.0.0.1:8000`, the proxy's default port; the proxy connects from
  inside the VM, so nothing needs to listen on the network interface.
- Secrets go in a root-only file read through `LoadCredential=`, never in
  `Environment=` or the image.

The drop-in on this VM is the source of truth for its image; background,
possibly newer than this VM:
https://github.com/tho/exeslim/blob/main/docs/deploying.md

Working on the exeslim repository itself rather than on a VM built from it?
This file is the image's agent context, not yours: read docs/developing.md.
