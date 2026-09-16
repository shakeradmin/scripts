#!/bin/bash
set -Eeuo pipefail

fetch_ok=0
for attempt in 1 2 3; do
  if curl -sH "Accept: application/vnd.github.v3.raw" "https://api.github.com/repos/shakeradmin/scripts/contents/setTailscale.sh" -o /tmp/setTailscale.sh; then
    fetch_ok=1
    break
  fi
  echo "WARNING: failed to fetch setTailscale.sh from GitHub (attempt $attempt); retrying in 3s" >&2
  sleep 3
done

if [ "$fetch_ok" -ne 1 ]; then
  echo "ERROR: could not fetch setTailscale.sh from GitHub after 3 attempts — aborting" >&2
  exit 1
fi

sudo TS_AUTHKEY=tskey-auth-kkdgXemiSd11CNTRL-pV1dXFH7aXMnkfEw6kH8XMtvXR4FovQtZ bash /tmp/setTailscale.sh
