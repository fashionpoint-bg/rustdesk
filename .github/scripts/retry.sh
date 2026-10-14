#!/usr/bin/env bash
# FashionPoint: runs a command until it succeeds, at most <attempts> times, pausing <delay>, 2 x <delay>, ...
# seconds between tries, and exits with the last try's status.
# For calls to outside services that fail now and then: Apple's timestamp and notary services, downloads.
# Usage: retry.sh <attempts> <delay seconds> <command> [arguments...]
set -uo pipefail

attempts=$1
delay=$2
shift 2

for ((try = 1; ; try++)); do
  "$@" && exit 0
  status=$?
  if ((try >= attempts)); then
    echo "retry.sh: $1 failed $try times, giving up (exit $status)" >&2
    exit "$status"
  fi
  echo "retry.sh: $1 failed (exit $status, try $try of $attempts), trying again in $((delay * try)) s" >&2
  sleep $((delay * try))
done
