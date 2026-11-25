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
  `fstrim-timer.conf`, `shelley.service`, `shelley.socket`,
  `distrust-emudhra.sh`, `LICENSE`, and the head of `AGENTS.md` and `Makefile`
  (the `check` target is appended). If one must differ, say why in the commit.
- exeslim's own files live where exeuntu has nothing: `image/`, `examples/`,
  `docs/`, `ci/`, `.github/`, `.hadolint.yaml`, `Dockerfile.shelley*`.

Merge only when some upstream change reaches exeslim's tree, including
upstream deleting a file exeslim kept. If every new upstream commit touches
only what exeslim removed, do not merge: the next merge that changes something
brings those commits along.

Resolving a merge: a conflict in the `Dockerfile` is upstream changing a line
exeslim deleted or its neighbour; keep the deletion unless the change is
platform wiring exe.dev depends on, in which case port it, in exeslim's own
terms if the base lacks the tool upstream uses (the git identity include is
written without git). A modify/delete conflict is upstream touching a file
exeslim removed (`cli/`, `pi-extension/`, the installers): `git rm` it again.
`AGENTS.md` conflicts when upstream changes its head: take upstream's head and
keep exeslim's sections below it. Then build and run the checks below.

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
- `svc-exec`: `image/svc-exec.sh`, the `HOME` bullet in `deploying.md`, the rule
  in `AGENTS.md`, and its check in `ci/check-image.sh`.
- The Shelley variants' packages: `Dockerfile.shelley`,
  `Dockerfile.shelley-full` and its header, the check in
  `ci/check-shelley.sh`, and the Shelley sections of `README.md` and
  `AGENTS.md`.
- The Shelley guard: `image/shelley-guard.nft`, which holds the reasons, and
  the sentences that point to it in `README.md`, `deploying.md` and
  `AGENTS.md`. CI reads the UID range from the rule.
- The git identity include: `/etc/gitconfig` written in the `Dockerfile`, its
  check in `ci/check-shelley.sh`, and the sentences in `README.md` and
  `AGENTS.md`.
- The golang build image, pinned by patch version and digest in
  `examples/hello/Dockerfile` and `ci/sandbox-probe/Dockerfile`; Dependabot
  bumps both in one pull request.
- The hello example's Dockerfile: `examples/hello/Dockerfile` and its copy in
  `deploying.md`, which names no Go version so that a Dependabot bump of the
  example does not touch it.

## Checking a change locally

First `hadolint Dockerfile* */*/Dockerfile` and `shellcheck -x ci/*.sh`, which
is what CI runs before it builds (hadolint as a recursive `Dockerfile*`, so a
new Dockerfile is linted without a workflow change; that glob skips hidden
directories, so keep Dockerfiles out of `.github/`). `.hadolint.yaml`
lists the rules this repository ignores and why; a rule that is wrong for one
instruction gets a `# hadolint ignore=` comment above that instruction, with
the reason above it. A finding in one of exeuntu's lines in the `Dockerfile`
is handled in `.hadolint.yaml`, not by editing the line.

Then `make check`, which runs what CI runs, on images tagged `dev`:

```sh
ci/build.sh dev            # base, hello, shelley, shelley-full
ci/check-image.sh dev      # the base, and hello booted on it
ci/check-shelley.sh dev    # the variants, shelley-full booted
```

`ci/build.sh dev base hello` builds only what `ci/check-image.sh` needs. CI
differs in the tag, in `DOCKER_DEFAULT_PLATFORM=linux/amd64`, in
`BUILDX_NO_DEFAULT_ATTESTATIONS=1`, and in taking the revision and created
labels from the run rather than from `HEAD` and the clock; see
`.github/workflows/build.yml`. A check that boots a container removes it when
it exits, after dumping its journal if the check failed. `make run` boots the
image under Docker with systemd as PID 1.

## Validating the hardening profile

CI runs `systemd-analyze security --offline=true --threshold=20` on the hello
example's unit inside the built image, so a configuration regression fails the
build, and boots hello under Docker. Neither shows that exe.dev's kernel
enforces what systemd configures; several of these settings are silently
disabled on a kernel or architecture that lacks them. That was last checked by
hand on 2026-10-11, from inside a `svc-` unit on an exe.dev VM. Repeat it when
the drop-in gains a setting or exe.dev changes its kernel.

CI also runs `ci/sandbox-probe` in a `svc-` unit: the seccomp and Landlock
system calls must pass the filter, and a Landlock ruleset must refuse a read.
That proves the filter, and Landlock on the runner's kernel only; on a runner
without Landlock the probe prints `landlock unavailable` and the step warns
instead of failing. On an exe.dev VM the probe last passed on 2026-11-15, with
Landlock ABI 6. Repeat it when exe.dev changes its kernel:

```sh
docker build --platform linux/amd64 -o probe ci/sandbox-probe
scp probe/sandbox-probe <vm>.exe.xyz:
ssh <vm>.exe.xyz 'sudo install -m 0755 sandbox-probe /usr/local/bin/ &&
  sudo systemd-run --quiet --wait --pipe --collect --unit=svc-sandbox-probe \
    sh -c "/usr/local/bin/sandbox-probe || true";
  sudo rm -f /usr/local/bin/sandbox-probe; rm -f sandbox-probe'
```

It must end with `landlock enforced`; `landlock unavailable` means the VM's
kernel has no Landlock. Otherwise it names the call that failed and whether
the filter or the kernel refused it. The `|| true` keeps the profile from
restarting a failed probe for ever, and the last line removes the probe from
the VM.

In prose, never use em dashes, en dashes or spaced hyphens as sentence
interrupters. exeuntu's own lines are exempt: they are kept verbatim.
