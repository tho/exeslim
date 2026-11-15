#!/usr/bin/env bash
# ci/build.sh: build the images that CI checks and publishes, into Docker's
# image store, where each derived image finds its base.
#
# Usage: ci/build.sh <build-id> [target...]
#   build-id  The tag: CI's immutable id, or "dev" locally.
#   target    base, hello, shelley or shelley-full, in that order, since each
#             builds on one before it. Default: all four.
#
# Environment: REVISION and CREATED become the OCI revision and created labels.
# CI sets both; the defaults are HEAD ("unknown" without git) and now.
#
# CI also sets BUILDX_NO_DEFAULT_ATTESTATIONS, see .github/workflows/build.yml.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

build=${1:?usage: ci/build.sh <build-id> [base|hello|shelley|shelley-full ...]}
shift
(($#)) || set -- base hello shelley shelley-full

revision=${REVISION:-$(git rev-parse HEAD 2>/dev/null || echo unknown)}
created=${CREATED:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}

# Only the docker driver builds into the image store, where a derived image
# finds its base; with another, FROM would pull a tag that was never pushed.
# Captured before it is searched: awk leaving early would break the pipe, and
# pipefail then fails the script with docker's status and no message.
builder=$(docker buildx inspect) || die "cannot inspect the selected buildx builder"
driver=$(awk '$1 == "Driver:" { print $2 }' <<<"$builder")
[[ $driver == docker ]] ||
  die "the selected buildx builder uses the '$driver' driver; select one that uses the docker driver"

for target in "$@"; do
  case $target in
    # BUILD_ID overrides ubuntu's "24.04" version label; the static labels
    # are in the Dockerfile.
    base)
      docker build \
        --build-arg "BUILD_ID=$build" \
        --label "org.opencontainers.image.revision=$revision" \
        --label "org.opencontainers.image.created=$created" \
        -t "$REPO:$build" .
      ;;
    # Its own labels: it would otherwise inherit the base's.
    hello)
      docker build \
        --build-arg "BASE=$REPO:$build" \
        --label org.opencontainers.image.title=exeslim-hello \
        --label "org.opencontainers.image.description=The hello example service from exeslim's examples/hello, on the exeslim base image." \
        --label "org.opencontainers.image.revision=$revision" \
        --label "org.opencontainers.image.created=$created" \
        -t "$REPO-hello:$build" examples/hello
      ;;
    # The variants' Dockerfiles override the descriptive labels; the rest
    # are inherited.
    shelley)
      docker build -f Dockerfile.shelley \
        --build-arg "BASE=$REPO:$build" \
        -t "$REPO:$build-shelley" .
      ;;
    shelley-full)
      docker build -f Dockerfile.shelley-full \
        --build-arg "BASE=$REPO:$build-shelley" \
        -t "$REPO:$build-shelley-full" .
      ;;
    *) die "unknown target: $target" ;;
  esac
done
