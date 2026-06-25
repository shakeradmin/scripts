#!/bin/bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

WIFI_NETWORK="${WIFI_NETWORK:-}"
WIFI_PASSWORD="${WIFI_PASSWORD:-}"

log() {
  echo "[$(date '+%F %T')] $1"
}

load_env() {
  if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    set +a
    WIFI_NETWORK="${WIFI_NETWORK:-}"
    WIFI_PASSWORD="${WIFI_PASSWORD:-}"
  else
    log "WARNING: .env not found at $ENV_FILE"
  fi
}

prompt_for_password() {
  local prompt="Enter Wi-Fi password for $WIFI_NETWORK: "

  if [ -r /dev/tty ]; then
    printf "%s" "$prompt" > /dev/tty
    IFS= read -rs WIFI_PASSWORD < /dev/tty
    printf "\n" > /dev/tty
  else
    IFS= read -rs -p "$prompt" WIFI_PASSWORD
    echo
  fi
}

try_connect() {
  if [ -n "$WIFI_PASSWORD" ]; then
    nmcli dev wifi connect "$WIFI_NETWORK" password "$WIFI_PASSWORD"
  else
    nmcli dev wifi connect "$WIFI_NETWORK"
  fi
}

main() {
  load_env

  if [ -z "$WIFI_NETWORK" ]; then
    log "ERROR: WIFI_NETWORK is missing from .env"
    exit 1
  fi

  if ! command -v nmcli >/dev/null 2>&1; then
    log "ERROR: nmcli is not installed"
    exit 1
  fi

  log "Trying Wi-Fi network: $WIFI_NETWORK"
  nmcli radio wifi on >/dev/null 2>&1 || true
  nmcli dev wifi rescan >/dev/null 2>&1 || true

  if try_connect >/dev/null 2>&1; then
    log "Connected to $WIFI_NETWORK using credentials from .env"
    exit 0
  fi

  log "Connection with .env credentials failed"
  prompt_for_password

  if try_connect >/dev/null 2>&1; then
    log "Connected to $WIFI_NETWORK"
    exit 0
  fi

  log "ERROR: Wi-Fi connection failed"
  exit 1
}

main "$@"
