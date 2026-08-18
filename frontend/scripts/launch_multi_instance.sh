#!/usr/bin/env bash
set -euo pipefail

# Launches several isolated copies of the Callbreak Linux desktop build side
# by side, for manually testing multiplayer flows (lobbies, reconnection,
# presence) without needing several physical machines.
#
# Each instance gets its own XDG_DATA_HOME (plus CONFIG/CACHE for hygiene).
# That's where shared_preferences_linux keeps its JSON file, which is what
# IdentityStore.open() (lib/state/identity_store.dart) reads and writes the
# device id from — a fresh data dir means IdentityStore finds nothing on
# first launch and mints a fresh uuid, so every instance ends up with its own
# device id automatically. No app code changes needed, and no two instances
# can ever collide on one by construction.
#
# Once the instances are up, this script also reads each one's device id
# back out of its isolated shared_preferences.json and prints them, so you
# can see with your own eyes that they're all different.
#
# To test reconnection: each table screen has a debug-only "Go offline (debug)"
# pill in the top-left corner (debug builds only — see the kDebugMode guard in
# lib/ui/screens/table_screen.dart). Tapping it severs that instance's socket
# through the exact same disconnect path a real network drop would
# (NetworkSession.simulateOffline in lib/net/remote_session.dart), so you get
# the real seat-held countdown and backoff behaviour. Tap it again to rejoin.
#
# Usage:
#   scripts/launch_multi_instance.sh [count] [--release|--profile] [--no-build]
#
# Examples:
#   scripts/launch_multi_instance.sh              # 4 instances, debug, builds first
#   scripts/launch_multi_instance.sh 2 --no-build  # 2 instances, reuse last build
#   scripts/launch_multi_instance.sh 3 --release   # 3 release-mode instances

COUNT="${1:-4}"
MODE="debug"
BUILD=1

for arg in "$@"; do
  case "$arg" in
    --release) MODE="release" ;;
    --profile) MODE="profile" ;;
    --no-build) BUILD=0 ;;
  esac
done

if ! [[ "$COUNT" =~ ^[0-9]+$ ]] || [[ "$COUNT" -lt 1 ]]; then
  echo "error: count must be a positive integer (got '$COUNT')" >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

BUNDLE="$ROOT_DIR/build/linux/x64/$MODE/bundle/callbreak"
RUN_ROOT="/tmp/callbreak_instances"

if [[ "$BUILD" == "1" ]]; then
  echo "==> Building Linux $MODE bundle..."
  flutter build linux "--$MODE"
fi

if [[ ! -x "$BUNDLE" ]]; then
  echo "error: $BUNDLE not found. Run without --no-build first." >&2
  exit 1
fi

rm -rf "$RUN_ROOT"
mkdir -p "$RUN_ROOT"

PIDS=()
cleanup() {
  echo
  echo "==> Stopping ${#PIDS[@]} instance(s)..."
  kill "${PIDS[@]}" 2>/dev/null || true
  wait 2>/dev/null || true
}
# EXIT alone would fire once for a normal finish; INT/TERM need their own trap
# too since bash suppresses the default terminate action once a handler is
# installed for them — but that handler must itself exit, or control falls
# through to the end of the script and the EXIT trap runs cleanup a second
# time on top of it.
trap cleanup EXIT
trap exit INT TERM

echo "==> Launching $COUNT instance(s) of $BUNDLE"

for i in $(seq 1 "$COUNT"); do
  instance_dir="$RUN_ROOT/instance_$i"
  mkdir -p "$instance_dir/data" "$instance_dir/config" "$instance_dir/cache"
  mkfifo "$instance_dir/out.fifo"

  # Stream each instance's stdout/stderr straight to this terminal, every line
  # tagged with its instance number, while tee keeps a raw copy in log.txt.
  # The bundle writes into a FIFO so we can grab its real PID ($!) for cleanup
  # while a separate cat/tee/sed pipeline demuxes the output.
  XDG_DATA_HOME="$instance_dir/data" \
  XDG_CONFIG_HOME="$instance_dir/config" \
  XDG_CACHE_HOME="$instance_dir/cache" \
  "$BUNDLE" >"$instance_dir/out.fifo" 2>&1 &
  BUNDLE_PID=$!
  cat "$instance_dir/out.fifo" | tee "$instance_dir/log.txt" | sed -E "s/^/  [instance $i] /" &

  PIDS+=("$BUNDLE_PID" "$!")
  echo "  instance $i: pid $BUNDLE_PID · log: $instance_dir/log.txt"
done

echo "==> Waiting for instances to mint their device id..."
sleep 3

echo
echo "==> device_id per instance:"
declare -A seen
duplicate=0
for i in $(seq 1 "$COUNT"); do
  prefs_file=$(find "$RUN_ROOT/instance_$i/data" -name "shared_preferences.json" 2>/dev/null | head -n1)
  if [[ -z "$prefs_file" ]]; then
    echo "  instance $i: (no prefs file yet — give it a moment and check $RUN_ROOT/instance_$i/data)"
    continue
  fi
  device_id=$(grep -o '"flutter\.identity\.deviceId":"[^"]*"' "$prefs_file" | sed -E 's/.*:"([^"]*)"/\1/')
  if [[ -z "$device_id" ]]; then
    echo "  instance $i: (device id not written yet)"
    continue
  fi
  echo "  instance $i: $device_id"
  if [[ -n "${seen[$device_id]:-}" ]]; then
    echo "      !! COLLISION with instance ${seen[$device_id]} — this should never happen"
    duplicate=1
  fi
  seen[$device_id]="$i"
done
echo
if [[ "$duplicate" == "0" ]]; then
  echo "==> All device ids unique."
else
  echo "==> WARNING: duplicate device ids detected — see above." >&2
fi

echo
echo "==> ${#PIDS[@]} instance(s) running. Windows may overlap; drag them apart."
echo "==> In each window, start/join a table and use the 'Go offline (debug)'"
echo "    pill top-left to test that instance's reconnection logic."
echo "==> Press Ctrl+C here to stop every instance."

wait
