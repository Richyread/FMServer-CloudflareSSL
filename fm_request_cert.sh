#!/usr/bin/env bash
set -u
set -o pipefail

#================================================================================
# This script runs the certbot generation and imports the certificate into FileMaker Server. This script is required to be ran
# as root for initial validation and to permit access to FileMaker Server for certificate import. Please ensure that FileMaker
# Server is running prior to running this script
# It sources configuration variables from a `.env` file located in the same directory as the script.

# Usage:
# sudo -E ./fm_request_cert.sh

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
    echo "[ERROR] .env file not found at $CONFIG_FILE. Please create it with required settings." 
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


#-------------------------------------------
# Check for Certbot installation
#-------------------------------------------

CERTBOT_CMD="certbot"
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    CERTBOT_CMD="/snap/bin/certbot"
elif [[ "$OSTYPE" == "darwin"* ]]; then
    CERTBOT_CMD=$(command -v certbot)
fi

if [[ ! -x "$CERTBOT_CMD" ]]; then
    echo "[ERROR] Certbot is not installed or not executable. Please resolve and rerun this script. Exiting..."
    exit 1
fi


#-----------------------------------
# Check for Filemaker Server Status
#-----------------------------------

isServerRunning() {
   pgrep -x fmserver > /dev/null
   return $?
}


#-------------------------------------------
# Define FMS Paths & Check Existing Certs
#-------------------------------------------

if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    CERTBOTPATH="/opt/FileMaker/FileMaker Server/CStore/Certbot"
elif [[ "$OSTYPE" == "darwin"* ]]; then
    CERTBOTPATH="/Library/FileMaker Server/CStore/Certbot"
fi

mkdir -p "$CERTBOTPATH"

# Check if cert already exists
if [[ -e "$CERTBOTPATH/live/$DOMAIN" ]]; then
    echo "[ERROR] Certificate directory already exists for $DOMAIN."
    echo "Please backup and remove \"$CERTBOTPATH/live/$DOMAIN\" before continuing."
    exit 1
fi


#-------------------------------------------
# Run Certbot
#-------------------------------------------

echo "Requesting Let's Encrypt certificate for domain: $DOMAIN using DNS-01 challenge"

CERTBOT_ARGS=(
    certonly
    --dns-cloudflare
    --dns-cloudflare-credentials "$CFAPI_PATH"
    --domain "$DOMAIN"
    --agree-tos
    --non-interactive
    --email "$EMAIL"
    --config-dir "$CERTBOTPATH"
    --work-dir "$CERTBOTPATH"
    --logs-dir "$CERTBOTPATH"
)

# Optional: add --dry-run for testing
if [[ "${TEST_CERTIFICATE:-0}" == "1" ]]; then
    CERTBOT_ARGS+=(--dry-run)
fi

# Optional: add --expand if multi-domain reissue
if [[ "${UPDATE_EXISTING_CERT:-0}" == "1" ]]; then
    CERTBOT_ARGS+=(--expand)
fi

"$CERTBOT_CMD" "${CERTBOT_ARGS[@]}"
RETVAL=$?

if [[ $RETVAL -ne 0 ]]; then
    echo "[ERROR] Certbot failed to request certificate. Check logs in $CERTBOTPATH/letsencrypt.log"
    exit 1
fi


#-------------------------------------------
# Import certificate into FileMaker Server
#-------------------------------------------

CERTFILEPATH=$(realpath "$CERTBOTPATH/live/$DOMAIN/fullchain.pem")
PRIVKEYPATH=$(realpath "$CERTBOTPATH/live/$DOMAIN/privkey.pem")

# if we are testing, we don't need to import/restart
if [[ "${TEST_CERTIFICATE:-0}" -eq 1 ]] ; then
    echo "[TEST] Dry-run test certificate created successfully."
    exit 0
fi

if [[ ! -f "$CERTFILEPATH" || ! -f "$PRIVKEYPATH" ]]; then
    echo "[ERROR] Certificate files not found after Certbot run."
    exit 1
fi

# Ensure correct ownership
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    chown -R fmserver:fmsadmin "$CERTFILEPATH" "$PRIVKEYPATH"
fi

echo "- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -"

# import certificates
echo "Importing Certificates:"
echo "Certificate: $CERTFILEPATH"
echo "Private key: $PRIVKEYPATH"

fmsadmin certificate import "$CERTFILEPATH" --keyfile "$PRIVKEYPATH" -y -u "$FAC_USERNAME" -p "$FAC_PASSWORD"
IMPORT_RETVAL=$?

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
# restarted, port 443 keeps serving the OLD certificate. We therefore use an atomic
# restart, confirm the service came back up, and verify on the wire that 443 is
# actually serving the new certificate.

if [[ "${RESTART_SERVER:-0}" == 1 ]] ; then
    echo "- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -"
    echo "Restarting FileMaker Server to load the new certificate..."

    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        # Atomic restart (single transaction). If your box uses a different
        # service/unit name, confirm it once with:
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
    sleep_interval=5
    max_wait="${MAX_WAIT_AMOUNT:-60}"
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
    # NOTE: on an initial request the public DNS for $DOMAIN may not yet point at this
    # box (cut-over often happens after setup), so a mismatch/unreachable result here is
    # a WARNING, not a hard failure — verify in the browser once DNS is in place. The
    # renewal script (fm_renew_cert.sh) treats this same check as a hard failure, since
    # by then DNS is established and this is the recurring stale-cert trap.
    if command -v openssl &> /dev/null; then
        echo "Verifying the certificate served on port 443 matches the newly issued one..."
        EXPECTED_ENDDATE=$(openssl x509 -enddate -noout -in "$CERTFILEPATH" 2>/dev/null | cut -d= -f2)

        SERVED_ENDDATE=$(echo | openssl s_client -connect "$DOMAIN:443" -servername "$DOMAIN" 2>/dev/null \
            | openssl x509 -enddate -noout 2>/dev/null | cut -d= -f2)

        if [[ -n "$SERVED_ENDDATE" && "$SERVED_ENDDATE" == "$EXPECTED_ENDDATE" ]]; then
            echo "[OK] Port 443 is serving the new certificate (expires: $SERVED_ENDDATE)."
        else
            echo "[WARNING] Could not confirm the new certificate on port 443 yet."
            echo "          Expected notAfter: $EXPECTED_ENDDATE"
            echo "          Served   notAfter: ${SERVED_ENDDATE:-<none / host not reachable at $DOMAIN>}"
            echo "          On an initial request this is usually just DNS not yet pointing here."
            echo "          Confirm in a browser once DNS for $DOMAIN resolves to this server."
        fi
    else
        echo "[WARNING] openssl not found — skipping on-the-wire certificate verification."
    fi
fi

echo "Lets Encrypt certificate request script completed without any errors."
