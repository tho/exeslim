#!/usr/bin/env bash
# ci/check-image.sh: check the base image, and the hello example on it.
#
# Usage: ci/check-image.sh <build-id>
#   build-id  The tag given to "ci/build.sh <build-id> base hello".
#
# Unbooted: exe.dev's metadata, load-bearing build steps, and the svc- profile
# via the image's own systemd-analyze on the hello unit. Booted: hello under
# systemd, svc-exec, and a svc- unit sandboxing itself. See
# docs/developing.md#validating-the-hardening-profile.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

build=${1:?usage: ci/check-image.sh <build-id>}
readonly IMAGE="$REPO:$build" HELLO="$REPO-hello:$build" C=exeslim-hello

# What exe.dev reads: proxy port, login user, version label.
meta=$(docker inspect "$IMAGE" --format \
  '{{json .Config.ExposedPorts}} {{index .Config.Labels "exe.dev/login-user"}} {{index .Config.Labels "org.opencontainers.image.version"}}')
[[ $meta == "{\"8000/tcp\":{}} exedev $build" ]] ||
  die "image metadata is wrong: $meta"

# machine-id is emptied after the last apt layer (packages write one). The
# /tmp override must match Ubuntu's file name to shadow its wipe-at-boot D
# line.
docker run --rm "$IMAGE" bash -euc '
  [[ ! -s /etc/machine-id && $(readlink /var/lib/dbus/machine-id) == /etc/machine-id ]]
  touch /tmp/keep && systemd-tmpfiles --remove && test -e /tmp/keep'

# AGENTS.md sends agents to the image's copy of deploying.md; it must be there
# and match the repository's.
readonly DEPLOYING_DOC=/usr/share/doc/exeslim/deploying.md
grep -qF "$DEPLOYING_DOC" AGENTS.md ||
  die "AGENTS.md does not point to $DEPLOYING_DOC"
docker run --rm "$IMAGE" cat "$DEPLOYING_DOC" | cmp -s - docs/deploying.md ||
  die "$DEPLOYING_DOC is missing or differs from docs/deploying.md"

# Threshold 20 is exposure 2.0; a unit the drop-in misses scores about 9.4.
docker run --rm "$HELLO" bash -euc '
  systemd-analyze verify svc-hello.service
  systemd-analyze security --offline=true --threshold=20 svc-hello.service'

boot "$C" "$HELLO"

# Unix-socket peer auth needs nss-systemd to resolve the dynamic user.
[[ $(docker exec "$C" getent passwd svc-hello | cut -d: -f1) == svc-hello ]] ||
  die "nss-systemd does not resolve svc-hello"

# init's low-port sysctl; its guard would skip a misspelt key silently. IPv6
# only where the host has it.
for key in ipv4/ip_unprivileged_port_start ipv6/ip_unprivileged_port_start; do
  [[ $key == ipv6/* ]] && ! docker exec "$C" test -e "/proc/sys/net/$key" && continue
  [[ $(docker exec "$C" cat "/proc/sys/net/$key") == 0 ]] ||
    die "init's sysctl net/$key is not 0"
done

docker exec "$C" curl -fsS --retry 10 --retry-connrefused --retry-delay 1 http://127.0.0.1:8000/

# svc-exec: a svc- unit has no HOME (systemd sets none under DynamicUser=), and
# the writable state directory through the wrapper. The user name shows the
# profile applied. The unit must exit 0: the profile would restart it and
# --wait hang. printenv, not ${HOME-}: systemd expands ${} in the command line
# before sh sees it.
# shellcheck disable=SC2016  # expanded by the sh inside the unit, not here
inner='echo "$HOME $XDG_CONFIG_HOME" && touch "$HOME/w" && echo writable'
out=$(docker exec "$C" systemd-run --quiet --wait --pipe --collect \
  --unit=svc-envcheck -p StateDirectory=envcheck \
  sh -c 'id -un; printenv HOME || echo unset; svc-exec sh -c "$0" || true' "$inner")
[[ $out == $'svc-envcheck\nunset\n/var/lib/envcheck /var/lib/envcheck/.config\nwritable' ]] ||
  die "svc-exec or a svc- unit's HOME is wrong:"$'\n'"$out"

# Without StateDirectory= it exits 78 and is not restarted (124 if it is).
status=0
docker exec "$C" timeout 30 systemd-run --quiet --wait --pipe --collect \
  --unit=svc-nostate /usr/local/bin/svc-exec true || status=$?
[[ $status == 78 ]] ||
  die "svc-exec without StateDirectory= did not fail the unit with 78: $status"

# A svc- unit can sandbox itself: the profile's filter passes seccomp(2) and
# Landlock, and this kernel enforces a Landlock ruleset. A kernel without
# Landlock only warns: the filter is still checked, and the image does not
# choose the host. Nonzero uid: the profile applied. Exits 0 as above.
TMP_DIR=$(mktemp -d)
docker build -o "$TMP_DIR" ci/sandbox-probe
docker cp "$TMP_DIR/sandbox-probe" "$C:/usr/local/bin/sandbox-probe"
probe=$(docker exec "$C" systemd-run --quiet --wait --pipe --collect \
  --unit=svc-sandbox-probe sh -c '/usr/local/bin/sandbox-probe || true')
re=$'^uid [1-9][0-9]*\nseccomp allowed\n(landlock abi [0-9]+\nlandlock enforced|landlock unavailable: [^\n]+)$'
[[ $probe =~ $re ]] ||
  die "a svc- unit cannot sandbox itself:"$'\n'"$probe"
[[ $probe != *"landlock unavailable"* ]] ||
  warn "Landlock enforcement not checked: ${probe##*$'\n'}"
