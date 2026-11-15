#!/usr/bin/env bash
# ci/check-shelley.sh: check the Shelley variants.
#
# Usage: ci/check-shelley.sh <build-id>
#   build-id  The tag given to ci/build.sh for base, shelley and shelley-full.
#
# Unbooted: metadata, the enabled socket (the label only installs the binary)
# and tools; the full variant's extra tools. Booted (full): the socket listens
# on 9999 and ~/.config/shelley as exedev, and image/shelley-guard.nft refuses
# a DynamicUser= process.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

build=${1:?usage: ci/check-shelley.sh <build-id>}
readonly C=exeslim-shelley

base=$(docker inspect "$REPO:$build" --format '{{index .Config.Labels "exe.dev/install-shelley"}}')
[[ $base != true ]] || die "base image has exe.dev/install-shelley=true"

for v in shelley shelley-full; do
  meta=$(docker inspect "$REPO:$build-$v" --format \
    '{{json .Config.ExposedPorts}} {{index .Config.Labels "exe.dev/login-user"}} {{index .Config.Labels "exe.dev/install-shelley"}} {{index .Config.Labels "org.opencontainers.image.version"}} {{index .Config.Labels "org.opencontainers.image.title"}}')
  [[ $meta == "{\"8000/tcp\":{},\"9999/tcp\":{}} exedev true $build exeslim-$v" ]] ||
    die "$v metadata is wrong: $meta"
  # Their apt layers can rewrite the machine-id the base emptied.
  docker run --rm "$REPO:$build-$v" bash -euc '
    test -L /etc/systemd/system/sockets.target.wants/shelley.socket
    systemd-analyze verify shelley-guard.service
    test -f /etc/systemd/system/shelley.socket.d/10-guard.conf
    [[ ! -s /etc/machine-id ]]
    for b in jq sqlite3 lsof; do command -v "$b" >/dev/null || { echo "missing $b"; exit 1; }; done' ||
    die "$v: shelley.socket, its guard, machine-id or tools are wrong"
done

# The guard's UID range must match systemd's build-time DynamicUser= range,
# recorded only in systemd-dev's pkg-config file.
guard=$(sed -n 's/.* meta skuid \([0-9]*\)-\([0-9]*\) .*/\1 \2/p' image/shelley-guard.nft)
read -r guard_min guard_max <<<"$guard"
[[ -n ${guard_max-} ]] || die "cannot read the UID range from image/shelley-guard.nft"
dynamic=$(docker run --rm "$REPO:$build-shelley" bash -euc '
  cd /tmp
  apt-get update -qq
  apt-get download -qq "systemd-dev=$(dpkg-query -W -f="\${Version}" systemd)"
  dpkg-deb --fsys-tarfile systemd-dev_*.deb | tar -xO ./usr/share/pkgconfig/systemd.pc >systemd.pc
  echo "$(sed -n "s/^dynamic_uid_min=//p" systemd.pc) $(sed -n "s/^dynamic_uid_max=//p" systemd.pc)"')
[[ $dynamic == "$guard_min $guard_max" ]] ||
  die "systemd allocates DynamicUser= UIDs from '$dynamic', the guard matches $guard_min-$guard_max"

docker run --rm "$REPO:$build-shelley-full" bash -euc '
  for b in /headless-shell/headless-shell ffmpeg ffprobe convert git; do
    command -v "$b" >/dev/null || { echo "missing $b"; exit 1; }
  done
  ! ldd /headless-shell/headless-shell | grep "not found"
  # The Shelley version check reads this; the binary cannot say.
  grep -q "^Chromium " /headless-shell/headless-shell-version.txt
  # distrust-emudhra.sh must have applied to the exedev NSS database.
  certutil -L -d sql:/home/exedev/.pki/nssdb | grep -q "^distrusted emSign ECC Root CA - G3 *p,p,p$"
  convert -list format | grep -q HEIC
  ffmpeg -hide_banner -encoders | grep -q libx264'

boot "$C" "$REPO:$build-shelley-full"

[[ -n $(docker exec "$C" ss -ltnH 'sport = :9999') ]] ||
  die "shelley.socket is not listening on 9999"
# ~/.config/shelley must stay exedev's, or Shelley cannot write it.
sock=$(docker exec "$C" stat -c '%U %F' /home/exedev/.config/shelley/shelley.sock /home/exedev/.config/shelley)
[[ $sock == $'exedev socket\nexedev directory' ]] ||
  die "shelley.sock or its directory is wrong:"$'\n'"$sock"

# A dynamic user is refused (exit 1, not a 124 timeout) while root is accepted,
# so the rule is what stopped it. Last: with no Shelley binary, root's
# connection leaves the socket nothing to start.
[[ $(docker exec "$C" systemctl is-active shelley-guard.service) == active ]] ||
  die "shelley-guard.service is not active"
connect='timeout 3 bash -c ": </dev/tcp/127.0.0.1/9999" 2>/dev/null'
probe=$(docker exec "$C" systemd-run --quiet --wait --pipe --collect -p DynamicUser=yes \
  bash -c "id -u; $connect; echo \$?")
uid=${probe%%$'\n'*}
((uid >= guard_min && uid <= guard_max)) ||
  die "DynamicUser= UID $uid is outside the range the guard matches"
[[ ${probe##*$'\n'} == 1 ]] ||
  die "a DynamicUser= process was not refused on Shelley's port (uid, exit status): $probe"
docker exec "$C" bash -c "$connect" ||
  die "root cannot reach Shelley's port, so the check above proves nothing"
