# syntax=docker/dockerfile:1

FROM ubuntu:24.04@sha256:68ee22004a9109b44973313b02ff7b1de250f1de0f5ecb628d73f579aaff33ac

# Switch from dash to bash by default.
SHELL ["/bin/bash", "-euxo", "pipefail", "-c"]


# Install a minimal package set, without recommends.
RUN apt-get update && \
	# Pull in all available security/bugfix updates for packages already
	# in the base ubuntu:24.04 image. Without this we ship whatever was
	# current when Canonical last rebuilt the base layer, which can be
	# months behind (e.g. nginx Rift, CVE-2026-42945). The weekly cron
	# rebuild + no-cache will keep this fresh going forward.
	DEBIAN_FRONTEND=noninteractive apt-get -y \
		-o Dpkg::Options::=--force-confold \
		-o Dpkg::Options::=--force-confdef \
		dist-upgrade && \
	# Pre-configure debconf to avoid interactive prompts
	echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections && \
	DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
		ca-certificates \
		locales \
		curl iproute2 \
		sudo tzdata \
		systemd systemd-sysv \
		dbus-user-session && \
	# en_US and en_GB only; locales-all is ~200 MB.
	locale-gen en_US.UTF-8 en_GB.UTF-8 && \
	update-locale LANG=en_US.UTF-8 && \
	# Remove policy-rc.d so services can start normally (the base image includes this
	# to prevent services from starting during build, but we run systemd at runtime)
	rm -f /usr/sbin/policy-rc.d && \
	apt-get clean && \
	rm -rf /var/lib/apt/lists/*

# exe-init manages DNS directly, so systemd-resolved has nothing to do.
RUN apt-get purge -y systemd-resolved

# Configure systemd
RUN systemctl mask -- getty.target \
		fwupd.service \
		fwupd-refresh.service \
		fwupd-refresh.timer \
		systemd-random-seed.service \
		iscsid.socket \
		dm-event.socket \
		man-db.timer \
		update-notifier-download.timer \
		update-notifier-motd.timer \
		atop-rotate.timer \
		dpkg-db-backup.timer \
		e2scrub_all.timer \
		etc-resolv.conf.mount \
		etc-hosts.mount \
		etc-hostname.mount \
		-.mount \
		systemd-remount-fs.service \
		systemd-sysusers.service \
		systemd-update-done.service \
		systemd-update-utmp.service \
		systemd-journal-catalog-update.service \
		modprobe@.service \
		systemd-modules-load.service \
		systemd-udevd.service \
		systemd-udevd-control.service \
		systemd-udevd-kernel.service \
		systemd-udev-trigger.service \
		systemd-udev-settle.service \
		systemd-hwdb-update.service \
		ubuntu-fan.service \
		ldconfig.service \
		unattended-upgrades.service \
		lxd-installer.socket \
	        console-getty.service \
		keyboard-setup.service \
		systemd-ask-password-console.path \
		systemd-ask-password-wall.path \
		ssh.socket \
		ssh.service \
		plymouth.service \
		plymouth-start.service \
		plymouth-quit.service \
		plymouth-quit-wait.service \
		plymouth-read-write.service \
		plymouth-switch-root.service \
		plymouth-switch-root-initramfs.service \
		plymouth-halt.service \
		plymouth-reboot.service \
		plymouth-poweroff.service \
		plymouth-kexec.service \
		apt-daily-upgrade.timer \
		apt-daily.timer \
		plymouth-log.service && \
	# systemd-logind is disabled but not masked. It's involved in populating the XDG runtime dir sockets... somehow
	systemctl disable getty.target systemd-logind.service \
                   console-getty.service \
                   getty@.service \
                   systemd-ask-password-wall.service \
                   systemd-ask-password-console.service \
                   systemd-machine-id-commit.service \
                   systemd-modules-load.service \
                   systemd-sysctl.service \
                   systemd-firstboot.service \
                   systemd-udevd.service \
                   systemd-udev-trigger.service \
                   systemd-udev-settle.service \
		   systemd-update-utmp.service \
                   systemd-hwdb-update.service \
		   e2scrub_reap.service && \
	mkdir -p /etc/systemd/system.conf.d && \
    		echo '[Manager]' > /etc/systemd/system.conf.d/container-overrides.conf && \
    		echo 'LogLevel=info' >> /etc/systemd/system.conf.d/container-overrides.conf && \
    		echo 'LogTarget=console' >> /etc/systemd/system.conf.d/container-overrides.conf && \
    		echo 'SystemCallArchitectures=native' >> /etc/systemd/system.conf.d/container-overrides.conf && \
    		echo 'DefaultOOMPolicy=continue' >> /etc/systemd/system.conf.d/container-overrides.conf && \
	mkdir -p /etc/systemd/journald.conf.d && \
		echo '[Journal]' > /etc/systemd/journald.conf.d/persistent.conf && \
		echo 'Storage=persistent' >> /etc/systemd/journald.conf.d/persistent.conf && \
	systemctl set-default multi-user.target

# Modify existing ubuntu user (UID 1000) to become exedev user
RUN usermod -l exedev -c "exe.dev user" ubuntu && \
	groupmod -n exedev ubuntu && \
	mv /home/ubuntu /home/exedev && \
	usermod -d /home/exedev exedev && \
	usermod -aG sudo exedev && \
	sed -i 's/^ubuntu:/exedev:/' /etc/subuid /etc/subgid && \
	echo 'exedev ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers && \
	echo 'Defaults:exedev verifypw=any' >> /etc/sudoers && \
	# Manually enable linger, this should autopopulate /run/user/1000
	mkdir -p /var/lib/systemd/linger && \
	touch /var/lib/systemd/linger/exedev

# Bake /etc/fstab so systemd-growfs@-.service resizes the root filesystem on
# first boot after the disk is grown.
RUN echo '/dev/vda / ext4 defaults,x-systemd.growfs 0 1' > /etc/fstab

# Stop systemd wiping /tmp at boot; that races non-systemd users of the system
# that also run at boot.
COPY tmpfiles-tmp.conf /etc/tmpfiles.d/tmp.conf

# https://github.com/trfore/docker-ubuntu2404-systemd/blob/main/Dockerfile suggests the following
# might be useful?
# STOPSIGNAL SIGRTMIN+3


RUN mkdir -p /home/exedev /home/exedev/.config/shelley && \
    chown exedev:exedev /home/exedev /home/exedev/.config /home/exedev/.config/shelley

USER exedev

WORKDIR /home/exedev

# Update PATH in .bashrc to include .local/bin and set XDG_RUNTIME_DIR for systemd user services
# XDG paths are not autopopulated despite the presense of libpam-systemd. Manually add them here.
RUN echo 'export PATH="$HOME/.local/bin:$PATH"' >> /home/exedev/.bashrc && \
    echo 'export XDG_RUNTIME_DIR="/run/user/$(id -u)"' >> /home/exedev/.bashrc && \
    echo 'export XDG_RUNTIME_DIR="/run/user/$(id -u)"' >> /home/exedev/.profile

# Switch back to root to install systemd service
USER root

# Disable Ubuntu's default MOTD (the sudo hint, etc.)
RUN rm -rf /etc/update-motd.d/* /etc/motd && touch /home/exedev/.hushlogin && chown exedev:exedev /home/exedev/.hushlogin

# Create systemd oneshot service for /exe.dev/setup script
COPY exe-setup.service /etc/systemd/system/exe-setup.service
RUN chmod 644 /etc/systemd/system/exe-setup.service && \
    systemctl enable exe-setup.service

# TODO(crawshaw/philip): This is called init so that exetini decides
# this wrapper script is an init, and exec's it rather than forking it.
# It would be better if you could indicate that via an env variable or something.
COPY init-wrapper.sh /usr/local/bin/init

# nss-systemd resolves DynamicUser= names (svc-<app>): a database's peer
# authentication on a Unix socket maps the service's UID to a role, and ps and
# ls show a name. The package enables itself in nsswitch.conf; check that it did.
RUN apt-get update && \
	DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends libnss-systemd && \
	apt-get clean && \
	rm -rf /var/lib/apt/lists/* && \
	grep -qE '^passwd:.* systemd' /etc/nsswitch.conf && \
	grep -qE '^group:.* systemd' /etc/nsswitch.conf

# Hardening profile for services. A prefix drop-in: it applies to every unit
# named svc-<app>.service that a derived image installs, and the base ships no
# such unit, so nothing here changes until one exists. See docs/deploying.md.
COPY --chmod=0644 image/svc-hardening.conf /etc/systemd/system/svc-.service.d/50-hardening.conf

COPY AGENTS.md /home/exedev/.config/shelley/AGENTS.md
RUN chown exedev:exedev /home/exedev/.config/shelley/AGENTS.md

# Empty the machine ID baked in by package configuration, so each VM built from
# this image generates its own on first boot. A shared one defeats anything that
# assumes machine IDs are unique, such as systemd's FixedRandomDelay=. Empty
# rather than removed: systemd reads an absent /etc/machine-id as a first boot
# and presets all units, re-enabling the ones disabled above. Keep this last, so
# that no apt-get install bakes in a new ID.
RUN : > /etc/machine-id && \
	ln -sf /etc/machine-id /var/lib/dbus/machine-id

# Expose the web server port. 9999 is Shelley's; the Shelley variants add it.
EXPOSE 8000

LABEL "exe.dev/login-user"="exedev"

# Default locale for systemd services and non-SSH contexts. Override per VM with
# `new --env LANG=...`, on the box with `update-locale`; an SSH session inherits
# the client's LANG. Only en_US.UTF-8 and en_GB.UTF-8 are generated.
ENV LANG=en_US.UTF-8

# OCI metadata, last: an ARG invalidates the build cache from where it is used,
# so a new BUILD_ID does not rebuild the layers above. ubuntu:24.04 ships
# org.opencontainers.image.version="24.04", which would otherwise be inherited.
ARG BUILD_ID=dev
LABEL org.opencontainers.image.title="exeslim" \
	org.opencontainers.image.description="Minimal exe.dev base image: systemd and the full platform wiring, without exeuntu's agent workstation toolchain." \
	org.opencontainers.image.source="https://github.com/tho/exeslim" \
	org.opencontainers.image.url="https://github.com/tho/exeslim" \
	org.opencontainers.image.licenses="Apache-2.0" \
	org.opencontainers.image.base.name="docker.io/library/ubuntu:24.04" \
	org.opencontainers.image.version="${BUILD_ID}"
CMD ["/usr/local/bin/init"]
