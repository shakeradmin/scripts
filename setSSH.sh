#!/bin/bash
set -Eeuo pipefail

curl -sH "Accept: application/vnd.github.v3.raw" "https://api.github.com/repos/shakeradmin/scripts/contents/setTailscale.sh" -o /tmp/setTailscale.sh
sudo TS_AUTHKEY=tskey-auth-kmQmA96HCq11CNTRL-r6U4HRHMHPWYKy2TMFHkPW6sXWnPnTjF bash /tmp/setTailscale.sh
