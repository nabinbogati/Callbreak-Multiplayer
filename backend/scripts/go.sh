#!/usr/bin/env sh
# Run a Go command, preferring a native toolchain and falling back to Docker.
#
# This machine may not have Go installed; `scripts/go.sh test ./...` works
# either way. Caches live under ~/.cache so nothing lands in the working tree,
# and the container runs as the invoking user so no root-owned files appear.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GO_IMAGE=${GO_IMAGE:-golang:1.26-alpine}
CACHE=${CALLBREAK_GO_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/callbreak-go}

if command -v go >/dev/null 2>&1; then
  cd "$ROOT" && exec go "$@"
fi

mkdir -p "$CACHE/build" "$CACHE/mod"
exec docker run --rm -i \
  --user "$(id -u):$(id -g)" \
  -v "$ROOT:/src" \
  -v "$CACHE/build:/gocache" \
  -v "$CACHE/mod:/gomodcache" \
  -e GOCACHE=/gocache \
  -e GOMODCACHE=/gomodcache \
  -e GOFLAGS="${GOFLAGS:-}" \
  -e UPDATE_GOLDEN="${UPDATE_GOLDEN:-}" \
  -w /src \
  "$GO_IMAGE" go "$@"
