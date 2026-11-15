#!/bin/sh
# Installed as /usr/local/bin/svc-exec. Runs a svc- unit's command with HOME
# and the XDG base directories in its StateDirectory=. See docs/deploying.md.
set -eu

# Exit status 78: the profile does not restart it, so the unit fails.
if [ -z "${STATE_DIRECTORY:-}" ]; then
	echo "svc-exec: STATE_DIRECTORY is not set; add StateDirectory= to the unit" >&2
	exit 78
fi
if [ "$#" -eq 0 ]; then
	echo "usage: svc-exec COMMAND [ARG...]" >&2
	exit 78
fi
# Else exec would exit 126 or 127, and the profile restart it for ever.
if ! command -v "$1" >/dev/null; then
	echo "svc-exec: $1: not found or not executable" >&2
	exit 78
fi

# The first entry when the unit lists several.
HOME=${STATE_DIRECTORY%%:*}
# The XDG directories only where the unit's Environment= has not set them.
XDG_CONFIG_HOME=${XDG_CONFIG_HOME:-$HOME/.config}
XDG_DATA_HOME=${XDG_DATA_HOME:-$HOME/.local/share}
XDG_STATE_HOME=${XDG_STATE_HOME:-$HOME/.local/state}
# CacheDirectory= if the unit has one (systemctl clean empties it), else state.
if [ -z "${XDG_CACHE_HOME:-}" ]; then
	XDG_CACHE_HOME=${CACHE_DIRECTORY:-$HOME/.cache}
	XDG_CACHE_HOME=${XDG_CACHE_HOME%%:*}
fi
export HOME XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME

exec "$@"
