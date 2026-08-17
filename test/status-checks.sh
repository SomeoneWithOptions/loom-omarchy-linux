#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
state=$(mktemp -d)
pid=
cleanup() { [[ -z $pid ]] || kill "$pid" 2>/dev/null || true; rm -rf "$state"; }
trap cleanup EXIT

status() { XDG_RUNTIME_DIR=$state "$repo/bin/loom-status"; }
[[ $(status) == inactive ]]

bash -c 'exec -a gpu-screen-recorder sleep 30' &
pid=$!
printf '%s\n' "$pid" >"$state/loom-recording.pid"
[[ $(status) == recording ]]
touch "$state/loom-paused"
[[ $(status) == paused ]]
kill "$pid"
wait "$pid" 2>/dev/null || true
pid=
[[ $(status) == inactive ]]

echo "PASS: Loom status follows recorder PID and pause state"
