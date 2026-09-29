#!/bin/bash
# The container lives in its own repository, checked out at <workspace>/container,
# so that a machine which only needs to rebuild the image needs nothing else.
# This forwards to it, because the old path is in muscle memory and in several
# procedures; keeping two copies of the real script is how they drift apart.
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL="${HERE}/container/ros2_docker.sh"

if [[ ! -x "$REAL" ]]; then
    echo "The container repository is not checked out at ${HERE}/container." >&2
    echo "Get it with:  vcs import < ${HERE}/container.repos" >&2
    echo "         or:  ./tari.bash --layer container" >&2
    exit 1
fi

exec "$REAL" "$@"
