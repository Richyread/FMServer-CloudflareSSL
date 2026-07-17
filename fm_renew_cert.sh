#!/usr/bin/env bash
set -u
set -o pipefail

#================================================================================
# FileMaker Server - Let's Encrypt Certificate Renewal Script
#
# This script renews an existing Let's Encrypt certificate using Certbot, 
# and imports the updated certificate into FileMaker Server.
# Script has been streamlined to focus on systems using the DNS-01 Challenge (e.g. via Cloudflare)
#
# Requirements:
# - Certbot must already be installed and a certificate must have been previously requested.
# - This script should be run as root using: sudo -E ./fm_renew_cert.sh
#
# Configuration:
# - Script reads from a `.env` file in the same directory for required settings.


#-----------------------------------
# Get script directory and load configuration from .env file
#-----------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/.env"

if [[ -f "$CONFIG_FILE" ]]; then
    echo "Loading configuration from $CONFIG_FILE"
    set -o allexport
    # shellcheck disable=SC1090  # .env path is runtime-resolved, not lintable
    source "$CONFIG_FILE"
    set +o allexport
else
    echo "[ERROR] Configuration (.env) file not found at $CONFIG_FILE. Exiting..." 
    exit 1
fi

#-------------------------------------------
# Validate required environment variables
#-------------------------------------------

if [[ -z "${DOMAIN:-}" || -z "${CFAPI_PATH:-}" || -z "${FAC_USERNAME:-}" || -z "${FAC_PASSWORD:-}" ]]; then
    echo "[ERROR] Missing required environment variables in .env file."
    echo "Ensure DOMAIN, CFAPI_PATH, FAC_USERNAME, and FAC_PASSWORD are set."
    exit 1
fi


#-----------------------------------
# Check for Certbot installation
#-----------------------------------

echo "Checking for Certbot..."
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    if [[ ! -e "/snap/bin/certbot" ]]; then
        echo "[ERROR] Certbot not installed. Please install Certbot and run fm_request_cert.sh first. Exiting..."
        exit 1
    fi
    CERTBOT_CMD="/snap/bin/certbot"
elif [[ "$OSTYPE" == "darwin"* ]]; then
    if ! command -v certbot &> /dev/null; then
        echo "[ERROR] Certbot not installed. Please install Certbot and run fm_request_cert.sh first. Exiting"
        exit 1
    fi
    CERTBOT_CMD="certbot"
else
   echo "[ERROR] Unsupported operating system: $OSTYPE. This script supports Linux and MacOS only."
   exit 1
fi

#-----------------------------------
# Check for Filemaker Server Status
#-----------------------------------

isServerRunning() {
   pgrep -x fmserver > /dev/null
   return $?
}


#-----------------------------------
# Define Certificate Path
#-----------------------------------

if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    CERTBOTPATH="/opt/FileMaker/FileMaker Server/CStore/Certbot"
    CSTOREPATH="/opt/FileMaker/FileMaker Server/CStore"
elif [[ "$OSTYPE" == "darwin"* ]]; then
    CERTBOTPATH="/Library/FileMaker Server/CStore/Certbot"
    CSTOREPATH="/Library/FileMaker Server/CStore"
fi

CERTFILEPATH="$CERTBOTPATH/live/$DOMAIN/fullchain.pem"
PRIVKEYPATH="$CERTBOTPATH/live/$DOMAIN/privkey.pem"

#-----------------------------------
# Verify certificate path exists
#-----------------------------------

if [[ ! -d "$CERTBOTPATH" ]]; then
    echo "[ERROR] Certificate directory not found at $CERTBOTPATH"
    exit 1
fi


#-----------------------------------
# Certbot Renew Certificate
#-----------------------------------

echo "Running Certbot renewal for domain: $DOMAIN"

CERTBOT_ARGS=(
    renew
    --cert-name "$DOMAIN"
    --dns-cloudflare
    --dns-cloudflare-credentials "$CFAPI_PATH"
    --config-dir "$CERTBOTPATH"
    --work-dir "$CERTBOTPATH"
    --logs-dir "$CERTBOTPATH"
)

# Optional: add --dry-run for testing
if [[ "${TEST_CERTIFICATE:-0}" == "1" ]]; then
    CERTBOT_ARGS+=(--dry-run)
fi

# Optional add --force-renew to always renew even if it is not expired

if [[ "${FORCE_RENEW:-0}" == "1" ]]; then
    CERTBOT_ARGS+=(--force-renew)
fi

"$CERTBOT_CMD" "${CERTBOT_ARGS[@]}"
RETVAL=$?

if [[ $RETVAL -ne 0 ]]; then
    echo "[ERROR] Certbot renewal failed. Check logs in $CERTBOTPATH/letsencrypt.log"
    exit 1
fi

echo "- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -"

# Fix certificate file ownership for FileMaker Server access
echo "Fixing certificate file ownership.."
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
   chown -R fmserver:fmsadmin "$CERTBOTPATH/archive/$DOMAIN/"
   chown -R fmserver:fmsadmin "$CERTBOTPATH/live/$DOMAIN/"
fi
# import certificates
echo "Importing Certificates:"
echo "Certificate: $CERTFILEPATH"
echo "Private key: $PRIVKEYPATH"

echo "- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -"

# Copy certificates to CStore for reliable import
echo "Copying certificates to CStore directory..."
cp "$CERTFILEPATH" "$CSTOREPATH/"
cp "$PRIVKEYPATH" "$CSTOREPATH/"
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    chown fmserver:fmsadmin "$CSTOREPATH/fullchain.pem"
    chown fmserver:fmsadmin "$CSTOREPATH/privkey.pem"
fi

# Import certificates from CStore
echo "Importing Certificates:"
echo "Certificate: $CSTOREPATH/fullchain.pem"
echo "Private key: $CSTOREPATH/privkey.pem"

fmsadmin certificate import "$CSTOREPATH/fullchain.pem" --keyfile "$CSTOREPATH/privkey.pem" -y -u "$FAC_USERNAME" -p "$FAC_PASSWORD"
# Capture the import result BEFORE the cleanup commands overwrite $? (previously the
# error check below tested the `rm` exit code, so a failed import was silently ignored).
IMPORT_RETVAL=$?

# Clean up temporary files
rm -f "$CSTOREPATH/fullchain.pem"
rm -f "$CSTOREPATH/privkey.pem"

if [[ $IMPORT_RETVAL -ne 0 ]]; then
    echo "[ERROR] FileMaker Server failed to import certificate."
    exit 1
fi


#-------------------------------------------
# FileMaker Server Restart + verification
#-------------------------------------------
# IMPORTANT: FileMaker Server bundles its own nginx, which reads the certificate
# into memory at start-up and does NOT re-read it when the file on disk changes.
# So a successful `fmsadmin certificate import` alone is NOT enough — until FMS is
# restarted, port 443 keeps serving the OLD certificate. This is the recurring
# "cert imported but stale cert still served on 443" failure mode. We therefore use
# an atomic restart, confirm the service came back up, and verify on the wire that
# 443 is actually serving the new certificate.

if [[ "${RESTART_SERVER:-0}" == 1 ]] ; then
    echo "- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -"
    echo "Restarting FileMaker Server to load the new certificate..."

    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        # Atomic restart (single transaction) replaces the old stop-wait-start, which
        # could leave the start step unconfirmed and nginx holding the old cert.
        # If your box uses a different service/unit name, confirm it once with:
        #   systemctl list-units --type=service | grep -iE 'fm|nginx'
        if command -v systemctl &> /dev/null; then
            systemctl restart fmshelper
        else
            # Fallback for non-systemd (older/SysV) hosts.
            service fmshelper restart
        fi
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        launchctl stop com.filemaker.fms
        launchctl start com.filemaker.fms
    fi

    # --- Verify the FileMaker Server process came back up ---
    sleep_interval=5                        # how often to poll for the process
    max_wait="${MAX_WAIT_AMOUNT:-60}"       # total seconds to allow the service to return
    max_attempt=$((max_wait/sleep_interval))
    waitCounter=0

    echo "Waiting for FileMaker Server to come back up..."
    while [[ $waitCounter -lt $max_attempt ]]; do
        isServerRunning && break
        printf "  ...waiting (%ds elapsed of %ds max)\n" $((waitCounter*sleep_interval)) "$max_wait"
        sleep $sleep_interval
        ((waitCounter++)) || true
    done

    if ! isServerRunning; then
        echo "[ERROR] FileMaker Server did not come back up within $max_wait seconds after restart."
        exit 1
    fi
    echo "FileMaker Server process is running."

    # --- Confirm the systemd service is active (Linux only) ---
    if [[ "$OSTYPE" == "linux-gnu"* ]] && command -v systemctl &> /dev/null; then
        if ! systemctl is-active --quiet fmshelper; then
            echo "[ERROR] fmshelper service is not active after restart."
            exit 1
        fi
        echo "fmshelper service is active."
    fi

    # --- Verify the NEW certificate is actually served on port 443 ---
    # Guards against the "imported but nginx still serving old cert" failure mode.
    if command -v openssl &> /dev/null; then
        echo "Verifying the certificate served on port 443 matches the newly issued one..."

        # Expected end date from the freshly issued cert on disk.
        EXPECTED_ENDDATE=$(openssl x509 -enddate -noout -in "$CERTFILEPATH" 2>/dev/null | cut -d= -f2)

        wire_ok=0
        SERVED_ENDDATE=""
        for attempt in 1 2 3 4 5 6; do   # nginx needs a few seconds to bind 443
            SERVED_ENDDATE=$(echo | openssl s_client -connect "$DOMAIN:443" -servername "$DOMAIN" 2>/dev/null \
                | openssl x509 -enddate -noout 2>/dev/null | cut -d= -f2)
            if [[ -n "$SERVED_ENDDATE" && "$SERVED_ENDDATE" == "$EXPECTED_ENDDATE" ]]; then
                wire_ok=1
                break
            fi
            echo "  ...cert on 443 not yet updated (attempt $attempt), waiting..."
            sleep 5
        done

        if [[ $wire_ok -eq 1 ]]; then
            echo "[OK] Port 443 is serving the new certificate (expires: $SERVED_ENDDATE)."
        else
            echo "[ERROR] Port 443 is still NOT serving the new certificate after restart."
            echo "        Expected notAfter: $EXPECTED_ENDDATE"
            echo "        Served   notAfter: ${SERVED_ENDDATE:-<none / host unreachable>}"
            echo "        This is the classic 'cert imported but nginx serving stale cert' failure."
            echo "        Try a full restart, or check for orphaned nginx processes holding the old cert."
            exit 1
        fi
    else
        echo "[WARNING] openssl not found — skipping on-the-wire certificate verification."
    fi
fi

echo "Lets Encrypt certificate renewal script completed without any errors."
