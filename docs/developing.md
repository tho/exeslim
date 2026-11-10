# Developing exeslim

This file is for people and agents working on the repo. `AGENTS.md` is not
addressed to you: it is exeuntu's agent context with exeslim's sections
appended, and the Dockerfile copies it into the image as
`~/.config/shelley/AGENTS.md` for agents running on VMs booted from exeslim.
Edit it only to change what those agents are told, and only below exeuntu's
lines.

## exeuntu is upstream

This repository's history starts at exeuntu's commits, and exeuntu is merged in
from time to time:

```sh
git remote add upstream https://github.com/boldsoftware/exeuntu.git   # once
git fetch upstream
git merge upstream/main
```

The diff against exeuntu reads as deletions plus a few appended files. Keep it
that way:

- The `Dockerfile` is exeuntu's text with lines deleted. Do not reorder,
  reformat or reword what survives; a cosmetic change is a merge conflict every
  time upstream touches that line. exeslim's additions (the locale, the
  hardening drop-in, the OCI labels) are blocks between exeuntu's, not edits
  inside them.
- Files exeuntu also has stay at exeuntu's path and content: `init-wrapper.sh`,
  `exe-setup.service`, `tmpfiles-tmp.conf`, `tmpfiles-shelley.conf`,
  `shelley.service`, `shelley.socket`, `distrust-emudhra.sh`, `LICENSE`, and the
  head of `AGENTS.md` and `Makefile`. If one must differ, say why in the commit.
- exeslim's own files live where exeuntu has nothing: `image/`, `examples/`,
  `docs/`, `.github/`, `.hadolint.yaml`, `Dockerfile.shelley*`.

Resolving a merge: a conflict in the `Dockerfile` is upstream changing a line
exeslim deleted or its neighbour; keep the deletion unless the change is
platform wiring exe.dev depends on, in which case port it. A modify/delete
conflict is upstream touching a file exeslim removed (`cli/`, `pi-extension/`,
the installers): `git rm` it again. `AGENTS.md` conflicts when upstream appends
to it: keep both. Then build and run the checks below.

Deliberately not carried over, so do not port them back: the agents, their
installers and their config directories, Go, uv, DuckDB, gh, Docker, Tailscale,
nginx, the MOTD, the terminfo, `unminimize`, `locales-all` and `ENV EXEUNTU=1`
(nothing in exeuntu reads it, and this image is not exeuntu). Also absent:
`openssh-server`, since exe.dev supplies its own sshd from `/exe.dev/bin`; a
firewall, since nothing listens on the network interface and exe.dev reaches
the VM over VSOCK and loopback (the Shelley variants' one rule is between local
users, not the network).

## Facts that live in several places

When you change one, update the others:

- The hardening profile: `image/svc-hardening.conf`, the rules in
  `deploying.md`, and the summary in `AGENTS.md`.
- The Shelley variants' packages: `Dockerfile.shelley`, `Dockerfile.shelley-full`
  and its header, the check in "Check the Shelley variants" in
  `.github/workflows/build.yml`, and the Shelley sections of `README.md` and
  `AGENTS.md`.
- The Shelley guard: `image/shelley-guard.nft`, which holds the reasons, and
  the sentences that point to it in `README.md`, `deploying.md` and
  `AGENTS.md`. CI reads the UID range from the rule.
- The hello example's Dockerfile: `examples/hello/Dockerfile` and its copy in
  `deploying.md`, which names no Go version so that a Dependabot bump of the
  example does not touch it.

## Checking a change locally

First `hadolint Dockerfile* examples/*/Dockerfile`, which is what CI runs
before it builds (as a recursive `Dockerfile*`, so a new Dockerfile anywhere
in the repository is linted without a workflow change). `.hadolint.yaml` lists
the rules this repository ignores and why; a rule that is wrong for one
instruction gets a `# hadolint ignore=` comment above that instruction, with
the reason above it. A finding in one of exeuntu's lines in the `Dockerfile`
is handled in `.hadolint.yaml`, not by editing the line.

`make build` (or `docker build -t ghcr.io/tho/exeslim:dev .`), then follow the
"Check the image" step in `.github/workflows/build.yml`, replacing
`${{ steps.tag.outputs.build }}` with `dev`. For the Shelley variants, also
`docker build -f Dockerfile.shelley --build-arg BASE=ghcr.io/tho/exeslim:dev -t ghcr.io/tho/exeslim:dev-shelley .`,
then `docker build -f Dockerfile.shelley-full --build-arg BASE=ghcr.io/tho/exeslim:dev-shelley -t ghcr.io/tho/exeslim:dev-shelley-full .`,
and follow "Check the Shelley variants" the same way. `make run` boots the
image under Docker with systemd as PID 1.

## Validating the hardening profile

CI runs `systemd-analyze security --offline=true --threshold=20` on the hello
example's unit inside the built image, so a configuration regression fails the
build, and boots hello under Docker. Neither shows that exe.dev's kernel
enforces what systemd configures; several of these settings are silently
disabled on a kernel or architecture that lacks them. That was last checked by
hand on 2026-10-11, from inside a `svc-` unit on an exe.dev VM. Repeat it when
the drop-in gains a setting or exe.dev changes its kernel.

In prose, never use em dashes, en dashes or spaced hyphens as sentence
interrupters. exeuntu's own lines are exempt: they are kept verbatim.
