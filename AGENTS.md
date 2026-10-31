You are running in an exe.dev VM.

https://exe.dev/docs/proxy.md has details about the exe.dev HTTPS proxy.

Only use documented exe.dev features (see https://exe.dev/docs.md). Undocumented local endpoints are internal infrastructure—unstable and unsupported.

## This VM runs exeslim, not exeuntu

It is a deployment target: a minimal base carrying systemd, TLS roots, curl,
`ss` (iproute2), sudo and ufw, and little else. Do not assume the usual
exeuntu toolbox is present.

**Not installed:** compiler (`build-essential`), Python, Node.js, Go, uv, Git,
Docker, nginx, Chrome. `apt` works, so `sudo apt-get install <pkg>` is fine for
anything you genuinely need, but prefer building artifacts elsewhere and
shipping them here, which is how this box is meant to be used.

**Exception, the Shelley image variants:** `-shelley` adds jq, sqlite3 and
lsof, and `-shelley-full` also adds Git, ffmpeg, ImageMagick and headless
Chrome (`/headless-shell`), for Shelley's own features. Still no compiler,
Python, Node.js, Go or Docker.

**Services are systemd units.** Start/stop with `systemctl`, and read logs with
`journalctl -u <name>`; journald storage is persistent, and with no toolchain
on the box it is the main debugging surface. `ss -tlnp` shows what is
listening.

**The app is a prebuilt binary** shipped in an image derived from exeslim, or
updated in place by `scp` and a restart. Anything you install directly on the
VM is lost if it is recreated from a fresh image, so durable changes belong in
the deploying repo, not on this VM.
