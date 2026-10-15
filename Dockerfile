# exeslim: a minimal exe.dev base image for deployment targets.
#
# exeuntu is deliberately a batteries-included agent workstation: it runs
# `unminimize`, reinstalls every package to restore man pages, then pulls in
# locales-all, ubuntu-server/standard/dev-tools, build-essential, Chrome + the
# GTK stack, ffmpeg, imagemagick, mitmproxy, docker, Go, uv, and the Claude /
# Codex / pi agents. That lands at ~3.4 GB before your app. Correct for a box
# where an agent might need anything; pure overhead for one static binary.
#
# This image drops all of that but keeps every piece of exe.dev *platform*
# wiring, correlated line-by-line against exeuntu's Dockerfile.
#
# NOT for interactive/agent VMs: no compiler, no python, no docker, no git.
# Use exeuntu for those.

FROM ubuntu:24.04@sha256:534baea6a22c03a63003dbc8dbe78fe34bc0d7e595d9a9dc9834884ff530eb55

SHELL ["/bin/bash", "-euxo", "pipefail", "-c"]

RUN apt-get update \
	# Pull security/bugfix updates for packages already in the base layer.
	# Without this we ship whatever was current when Canonical last rebuilt
	# ubuntu:24.04, which can be months behind, and since the packages we
	# install by name are only a handful, everything else would stay stale
	# no matter how often the weekly job reruns. Same reasoning as exeuntu.
	&& DEBIAN_FRONTEND=noninteractive apt-get -y \
		-o Dpkg::Options::=--force-confold \
		-o Dpkg::Options::=--force-confdef \
		dist-upgrade \
	&& DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
		systemd systemd-sysv dbus dbus-user-session \
		ca-certificates curl \
		# iproute2 for `ss`. ~1 MB, and it is the difference between seeing
		# and guessing when a unit is active but the proxy returns nothing:
		# is anything listening on the proxy port, and which process is it?
		iproute2 \
		# UFW provides the runtime firewall: it denies all direct inbound
		# network traffic. Observed, not documented by exe.dev: SSH and the
		# reverse proxy arrive over VSOCK to exe-init, not the network
		# interface, so this should not affect normal use. See
		# docs/internals.md#whats-in-it.
		ufw \
		sudo tzdata locales \
	# en_US + en_GB only; exeuntu installs locales-all, which is ~200 MB.
	# en_US.UTF-8 is the default as the least surprising for anyone else who
	# lands on the box. See the ENV LANG note below for how to override.
	&& locale-gen en_US.UTF-8 en_GB.UTF-8 \
	&& update-locale LANG=en_US.UTF-8 \
	# The base image ships policy-rc.d to stop services starting during build.
	# We run systemd at runtime, so it must go or apt-installed services will
	# silently fail to start on the VM.
	&& rm -f /usr/sbin/policy-rc.d \
	&& apt-get clean \
	&& rm -rf /var/lib/apt/lists/*

# Observed, not documented by exe.dev: the platform supplies /etc/resolv.conf
# as a plain file, so systemd-resolved has nothing to do. Remove it.
RUN apt-get purge -y systemd-resolved

# --- systemd, tuned for exe.dev's container-as-VM environment -----------------
# Units that hang, fail noisily, or fight the platform. Masking is safe for
# units that aren't installed, so this list can stay close to exeuntu's.
# NB: ssh.service/ssh.socket are masked because exe.dev supplies its own sshd
# from /exe.dev/bin; a distro sshd would contend for :22.
RUN systemctl mask -- \
		getty.target \
		console-getty.service \
		keyboard-setup.service \
		ssh.service \
		ssh.socket \
		systemd-remount-fs.service \
		systemd-sysusers.service \
		systemd-update-done.service \
		systemd-update-utmp.service \
		systemd-journal-catalog-update.service \
		systemd-random-seed.service \
		systemd-modules-load.service \
		modprobe@.service \
		systemd-udevd.service \
		systemd-udevd-control.socket \
		systemd-udevd-kernel.socket \
		systemd-udev-trigger.service \
		systemd-udev-settle.service \
		systemd-hwdb-update.service \
		systemd-ask-password-console.path \
		systemd-ask-password-wall.path \
		ldconfig.service \
		man-db.timer \
		dpkg-db-backup.timer \
		e2scrub_all.timer \
		apt-daily.timer \
		apt-daily-upgrade.timer \
		unattended-upgrades.service \
		iscsid.socket \
		dm-event.socket \
		ubuntu-fan.service \
		-.mount \
		etc-resolv.conf.mount \
		etc-hosts.mount \
		etc-hostname.mount \
	# systemd-logind is disabled but NOT masked; per exeuntu, it is involved
	# in populating the XDG runtime dir sockets.
	# Braces keep `|| true` bound to the disable alone, so a failed mask above
	# still aborts the build.
	&& { systemctl disable systemd-logind.service || true; } \
	&& { systemctl disable systemd-machine-id-commit.service systemd-firstboot.service systemd-sysctl.service || true; } \
	&& mkdir -p /etc/systemd/system.conf.d \
	&& printf '[Manager]\nLogLevel=info\nSystemCallArchitectures=native\nDefaultOOMPolicy=continue\n' \
		>/etc/systemd/system.conf.d/container-overrides.conf \
	# Deny all direct inbound network traffic, permissive outbound. No
	# exception for exe.dev: as observed (not documented), its SSH and proxy
	# traffic arrives over VSOCK, which bypasses the network stack and so
	# UFW. These rules stop anything else from reaching the guest over the
	# actual network interface.
	&& ufw default deny incoming \
	&& ufw default allow outgoing \
	&& sed -ri 's/^ENABLED=.*/ENABLED=yes/' /etc/ufw/ufw.conf \
	&& systemctl enable ufw.service \
	# Keep journals across reboots: `journalctl -u <svc>` is the only real
	# debugging surface on a box with no toolchain.
	&& mkdir -p /etc/systemd/journald.conf.d \
	&& printf '[Journal]\nStorage=persistent\n' \
		>/etc/systemd/journald.conf.d/persistent.conf \
	&& systemctl set-default multi-user.target

# CRITICAL: without this, systemd-growfs@-.service never runs and the root
# filesystem stays at its original size when the disk is grown, so
# `new --disk=50GB` or `resize` silently gives you an unexpanded fs.
RUN echo '/dev/vda / ext4 defaults,x-systemd.growfs 0 1' >/etc/fstab

# Stop systemd wiping /tmp at boot; it races non-systemd users that run at boot.
COPY tmpfiles-tmp.conf /etc/tmpfiles.d/tmp.conf

# Makes `new --setup-script` work. Without this unit the flag is accepted and
# then silently does nothing.
COPY --chmod=0644 exe-setup.service /etc/systemd/system/exe-setup.service
RUN systemctl enable exe-setup.service

# Hardening profile for services. A prefix drop-in: it applies to every unit
# named svc-<app>.service that a derived image installs, and the base ships no
# such unit, so nothing here changes until one exists. svc-check lets a derived
# image's CI assert the profile is in force. See docs/deploying.md.
COPY --chmod=0644 image/svc-hardening.conf /etc/systemd/system/svc-.service.d/50-hardening.conf
COPY --chmod=0755 image/svc-check /usr/local/bin/svc-check

# --- exedev user -------------------------------------------------------------
# Rename the stock ubuntu user (uid 1000) rather than delete/recreate, so uid,
# gid, home and subuid/subgid ranges all line up with exeuntu.
RUN usermod -l exedev -c "exe.dev user" ubuntu \
	&& groupmod -n exedev ubuntu \
	&& mv /home/ubuntu /home/exedev \
	&& usermod -d /home/exedev exedev \
	&& usermod -aG sudo exedev \
	&& sed -i 's/^ubuntu:/exedev:/' /etc/subuid /etc/subgid \
	&& printf 'exedev ALL=(ALL) NOPASSWD:ALL\nDefaults:exedev verifypw=any\n' >/etc/sudoers.d/exedev \
	&& chmod 0750 /etc/sudoers.d \
	&& chmod 0440 /etc/sudoers.d/exedev \
	# Linger populates /run/user/1000 so systemd --user works.
	&& mkdir -p /var/lib/systemd/linger \
	&& touch /var/lib/systemd/linger/exedev

RUN printf 'export PATH="$HOME/.local/bin:$PATH"\nexport XDG_RUNTIME_DIR="/run/user/$(id -u)"\n' \
		>>/home/exedev/.bashrc \
	&& printf 'export XDG_RUNTIME_DIR="/run/user/$(id -u)"\n' >>/home/exedev/.profile \
	&& rm -rf /etc/update-motd.d/* /etc/motd \
	&& touch /home/exedev/.hushlogin \
	&& chown exedev:exedev /home/exedev/.hushlogin /home/exedev/.bashrc /home/exedev/.profile

# Agent context. No agent ships in this image, but one may be installed later
# (`exe.dev/install-shelley`, or a hand-installed Claude/Codex/pi), and these
# files cost ~1 KB. Canonical copy lives at the XDG path Shelley reads, with
# the other agents symlinked to it, same layout as exeuntu. The source is
# image/agent-context.md: the repo's own AGENTS.md is for agents developing
# exeslim, not for agents running on it.
COPY image/agent-context.md /home/exedev/.config/shelley/AGENTS.md
RUN mkdir -p /home/exedev/.claude /home/exedev/.codex /home/exedev/.pi \
	&& ln -s /home/exedev/.config/shelley/AGENTS.md /home/exedev/.claude/CLAUDE.md \
	&& ln -s /home/exedev/.config/shelley/AGENTS.md /home/exedev/.codex/AGENTS.md \
	&& ln -s /home/exedev/.config/shelley/AGENTS.md /home/exedev/.pi/AGENTS.md \
	&& chown -R exedev:exedev \
		/home/exedev/.config /home/exedev/.claude /home/exedev/.codex /home/exedev/.pi

# exe.dev supplies its own sshd/sftp-server/sh from /exe.dev/bin, so no
# openssh-server here. Verified against a stock ubuntu:24.04 VM.
#
# The file MUST be named `init`: exe.dev's exetini decides this is an init
# from the basename and execs it rather than forking it.
COPY --chmod=0755 init /usr/local/bin/init

# Empty the machine ID that systemd's and dbus's package configuration baked in
# during the apt layer above. Left as-is, every VM created from this image
# shares one identity, which defeats anything that assumes machine IDs are
# unique (systemd's FixedRandomDelay=, for one). Emptied rather than removed:
# systemd reads an *absent* /etc/machine-id as first boot and presets all units,
# re-enabling the ones disabled above. Must stay after the last apt-get install,
# or a later package configure bakes in a fresh one. Mirrors exeuntu.
RUN : >/etc/machine-id \
	&& ln -sf /etc/machine-id /var/lib/dbus/machine-id

# Sets the default proxy port. Without an EXPOSE, exe.dev defaults to :80
# (verified on a stock ubuntu:24.04 VM); exeuntu exposes 8000 and 9999, the
# latter being Shelley's. We have no Shelley, so 8000 alone.
EXPOSE 8000

# Default locale for systemd services and non-SSH contexts. Three ways to
# override, in increasing order of precedence:
#
#   1. per VM, at creation:  ssh exe.dev new --env LANG=en_GB.UTF-8 ...
#   2. on the box:           sudo update-locale LANG=en_GB.UTF-8
#   3. per SSH session:      macOS ssh_config forwards LANG via SendEnv, so an
#                            interactive login already inherits the client's.
#
# Only en_US.UTF-8 and en_GB.UTF-8 are generated (exeuntu ships locales-all at
# ~200 MB). Connecting with any other LANG gives setlocale warnings; add it to
# locale-gen above if you need one.
ENV LANG=en_US.UTF-8

LABEL "exe.dev/login-user"="exedev"
# Add this if you want Shelley (and `new --prompt`) on VMs from this image:
# LABEL "exe.dev/install-shelley"="true"

# --- OCI metadata -------------------------------------------------------------
# Declared here, at the end, on purpose: an ARG invalidates the build cache from
# the point it is *used*, so keeping it below the apt layers means a new BUILD_ID
# does not trigger a full rebuild.
#
# `org.opencontainers.image.version` in particular must be set: ubuntu:24.04 ships
# that label as "24.04" and it is inherited, so without an override every scanner
# and `docker inspect` reports this image's version as Ubuntu's.
ARG BUILD_ID=dev
LABEL org.opencontainers.image.title="exeslim" \
	org.opencontainers.image.description="Minimal exe.dev base image for deployment targets: systemd and full platform wiring, without the agent workstation toolchain." \
	org.opencontainers.image.source="https://github.com/tho/exeslim" \
	org.opencontainers.image.url="https://github.com/tho/exeslim" \
	org.opencontainers.image.licenses="MIT" \
	org.opencontainers.image.base.name="docker.io/library/ubuntu:24.04" \
	org.opencontainers.image.version="${BUILD_ID}"

WORKDIR /home/exedev
CMD ["/usr/local/bin/init"]
