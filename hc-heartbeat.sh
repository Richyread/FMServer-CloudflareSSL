#!/usr/bin/env bash
# hc-heartbeat.sh — daily box heartbeat ping (healthchecks.io)
#
# Part of the Backup & Drop Monitoring Watchdog, Phase 2 (box heartbeats).
# Pings this box's check URL once a day. If the box is powered off, has lost
# outbound internet, or cron has stopped running, the ping never arrives and
# healthchecks.io alerts after its grace window.
#
# What it proves: the box is powered and can reach the internet.
# What it does NOT prove: tailnet health, or that any backup job ran. Those
# are the job success-pings, which are separate checks.
#
# Generic by design: this file is identical on every box. Only PING_URL below
# differs. Never commit a real ping URL — anyone holding one can spoof a
# healthy ping and suppress the alert. Install mode 700 root for that reason.

set -uo pipefail

# --- Config: this box's check ------------------------------------------------
# PING_URL = the full healthchecks.io ping URL for THIS box's heartbeat check,
#            pasted exactly as copied (it already starts https://).
PING_URL="PASTE_HEALTHCHECKS_PING_URL_HERE"

CONNECT_TIMEOUT=10

if [ "$PING_URL" = "PASTE_HEALTHCHECKS_PING_URL_HERE" ]; then
  logger -t hc-heartbeat "FAIL: PING_URL is still the placeholder — not configured"
  exit 1
fi

if curl -fsS -m "$CONNECT_TIMEOUT" --retry 3 "$PING_URL" >/dev/null; then
  logger -t hc-heartbeat "OK: heartbeat pinged"
else
  logger -t hc-heartbeat "WARN: heartbeat ping failed — box up, hc.io unreachable"
  exit 1
fi
