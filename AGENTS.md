You are running in an exe.dev VM (https://exe.dev/docs.md).

## This VM runs exeslim, not exeuntu

A minimal base. Assume no compiler, Python, Node.js, Go, Git or Docker, and no
`wget` or `netstat` (use curl and `ss`). Check with `command -v`, and use `apt`
for what is missing. On Shelley images, leave `shelley-guard.service` in place.

**Services:** only units named `svc-<app>.service` get the hardening drop-in.
Never add `User=` or put secrets in `Environment=`. Before writing or changing
a service, read `/usr/share/doc/exeslim/deploying.md`.

Working on the exeslim repository itself rather than on a VM built from it?
This file is not for you: read docs/developing.md.
