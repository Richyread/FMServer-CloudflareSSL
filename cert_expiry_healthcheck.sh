#!/usr/bin/env bash
# cert_expiry_healthcheck.sh — daily active-probe cert-expiry reminder (healthchecks.io)
#
# Part of the Backup & Drop Monitoring Watchdog, Phase 4 (FM-server cert reminders).
# Pings the check URL ONLY while the cert still has > THRESHOLD_DAYS remaining.
# When the cert drops to/at the threshold — OR a renewal silently failed, OR the
# cert can't be read at all — it withholds the ping, so healthchecks.io alerts
# after its grace window = "re-run the DNS-01 renewal now".
#
# Generic by design: this file is identical on every box. Only the CERTS lines
# below differ per box (same pattern as the renewal script's .env).

set -uo pipefail

# --- Config: one line per cert THIS box should probe -------------------------
# Format:  "FQDN:PORT|PING_URL"
#   FQDN     = the certificate's fully-qualified domain name. Probe each box
#              against its OWN :443 so SNI selects the right cert.
#   PING_URL = the full healthchecks.io ping URL for this cert's check, pasted
#              exactly as copied from healthchecks.io (it already starts https://).
# Replace BOTH placeholders below with real values on the box; leave this repo
# copy generic (a real ping URL is a spoofable secret — never commit it).
CERTS=(
  "CERT_FQDN_HERE:443|PASTE_HEALTHCHECKS_PING_URL_HERE"
)

THRESHOLD_DAYS=14     # ping only while MORE than this many days remain
CONNECT_TIMEOUT=10

for entry in "${CERTS[@]}"; do
  target="${entry%%|*}"
  ping_url="${entry##*|}"
  host="${target%%:*}"

  # Read the cert actually being served on the wire (works even if expired).
  enddate=$(echo | openssl s_client -connect "$target" -servername "$host" 2>/dev/null \
            | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)

  if [ -z "$enddate" ]; then
    logger -t cert-healthcheck "FAIL: could not read cert for $target — withholding ping (fail-safe)"
    continue                       # no ping => hc.io alerts after grace
  fi

  exp_epoch=$(date -d "$enddate" +%s 2>/dev/null)
  if [ -z "$exp_epoch" ]; then
    logger -t cert-healthcheck "FAIL: unparseable enddate '$enddate' for $target — withholding ping"
    continue
  fi

  days=$(( (exp_epoch - $(date +%s)) / 86400 ))

  if [ "$days" -gt "$THRESHOLD_DAYS" ]; then
    if curl -fsS -m "$CONNECT_TIMEOUT" --retry 3 "$ping_url" >/dev/null; then
      logger -t cert-healthcheck "OK: $target has ${days}d left — pinged healthy"
    else
      logger -t cert-healthcheck "WARN: $target healthy (${days}d) but hc.io ping failed"
    fi
  else
    logger -t cert-healthcheck "DUE: $target has ${days}d left (<= ${THRESHOLD_DAYS}) — withholding ping so hc.io alerts"
  fi
done
