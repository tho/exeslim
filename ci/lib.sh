# ci/lib.sh: shared by the ci/ scripts. Source it, do not run it.
# shellcheck shell=bash

# Paths in the ci/ scripts are relative to the repository root.
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

# The hello example is published beside it, as "$REPO-hello".
# shellcheck disable=SC2034  # used by the scripts that source this file
readonly REPO=ghcr.io/tho/exeslim

# Set by boot and by a script that makes a temporary directory; both are
# removed when the script exits.
BOOTED=''
TMP_DIR=''

die() {
  echo "error: $*" >&2
  exit 1
}

# warn <message>: an annotation on the run in GitHub Actions, where a line in
# the log would be missed.
warn() {
  if [[ -n ${GITHUB_ACTIONS:-} ]]; then
    echo "::warning::$*"
  else
    echo "warning: $*" >&2
  fi
}

# cleanup: the EXIT trap. A failure in a booted container is otherwise mute
# (a boot that never finishes says only that), so dump it before removing it,
# folded in GitHub Actions so that the error above it stays in view. Nothing
# here may change the script's exit status.
cleanup() {
  local status=$?
  if [[ -n $BOOTED ]]; then
    if ((status != 0)); then
      {
        [[ -z ${GITHUB_ACTIONS:-} ]] || echo "::group::$BOOTED: logs, failed units, journal"
        docker logs "$BOOTED" 2>&1 | tail -n 100
        docker exec "$BOOTED" systemctl --failed --no-pager
        docker exec "$BOOTED" journalctl -b --no-pager | tail -n 200
      } >&2 || true
      [[ -z ${GITHUB_ACTIONS:-} ]] || echo "::endgroup::" >&2
    fi
    docker rm -f -v "$BOOTED" >/dev/null 2>&1 || true
  fi
  [[ -z $TMP_DIR ]] || rm -rf -- "$TMP_DIR" || true
}
trap cleanup EXIT

# boot <name> <image>: run the image with systemd as PID 1 and wait until it
# has booted. Fails if a unit failed, except systemd-growfs-root, which cannot
# work in Docker (so "degraded" is expected). BOOTED is set only once the
# container is this run's: if the name is taken, it is another run's.
boot() {
  local name=$1 image=$2 deadline state failed
  local booted='^(running|degraded)$'
  docker run -d --name "$name" --privileged --tmpfs /run --tmpfs /run/lock "$image"
  BOOTED=$name
  deadline=$((SECONDS + 120))
  until
    state=$(docker exec "$name" systemctl is-system-running 2>/dev/null)
    [[ $state =~ $booted ]]
  do
    ((SECONDS < deadline)) || die "$name did not boot within 120s"
    sleep 1
  done
  failed=$(docker exec "$name" systemctl --failed --plain --no-legend | awk '{print $1}')
  [[ -z $failed || $failed == systemd-growfs-root.service ]] ||
    die "unexpected failed units: $failed"
}
