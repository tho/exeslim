# Developing exeslim

This repo builds exeslim, a minimal exe.dev base image for single-service
deployment VMs. This file is for agents working on the repo.

`image/agent-context.md` is not addressed to you. The Dockerfile copies it into
the image as `~/.config/shelley/AGENTS.md`, for agents running on VMs booted
from exeslim. Edit it only to change what those agents are told.

The design and its evidence are in `docs/internals.md`, including the
correlation with exeuntu. Changing the hardening drop-in means running the probe
by hand: see "Validating the hardening profile" there.

Some facts live in several places. When you change one, update the others:

- The hardening profile: `image/svc-hardening.conf`, the `want` list and header
  in `image/svc-check`, the table and `svc-check` paragraph in
  `docs/deploying.md`, and the summary in `image/agent-context.md`.
- The probe's checks: `probe/main.go` and the list and "16 checks" counts in
  `docs/internals.md`.
- The published tags: `.github/workflows/build.yml` and "Picking a tag" in
  `docs/operating.md`.

To check a change locally, `docker build -t exeslim:ci .`, then follow the
"Check the image" step in `.github/workflows/build.yml`.

In prose, never use em dashes, en dashes or spaced hyphens as sentence
interrupters.
