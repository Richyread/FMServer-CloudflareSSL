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
    echo "[TEST] Dry-run test certificate created."
    exit 1
fi

if [[ ! -f "$CERTFILEPATH" || ! -f "$PRIVKEYPATH" ]]; then
    echo "[ERROR] Certificate files not found after Certbot run."
    exit 1
fi

# Ensure correct ownership
chown -R fmserver:fmsadmin "$CERTFILEPATH" "$PRIVKEYPATH"

echo "- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -"

# import certificates
echo "Importing Certificates:"
echo "Certificate: $CERTFILEPATH"
echo "Private key: $PRIVKEYPATH"

fmsadmin certificate import "$CERTFILEPATH" --keyfile "$PRIVKEYPATH" -y -u $FAC_USERNAME -p $FAC_PASSWORD

if [[ $? -ne 0 ]]; then
    echo "[ERROR] FileMaker Server failed to import certificate."
    exit 1
fi


#-------------------------------------------
# Optional FileMaker Server Restart
#-------------------------------------------

if [[ "${RESTART_SERVER:-0}" == 1 ]] ; then
    echo "- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -"
    echo "Commencing FileMaker Server Service Restart."

# stop the filemaker service
    if   isServerRunning; then
            if [[ "$OSTYPE" == "linux-gnu"* ]]; then
                service fmshelper stop
            elif [[ "$OSTYPE" == "darwin"* ]]; then
                launchctl stop com.filemaker.fms
            fi
    fi

# now wait for the service to have completely stopped
# create some temporary variables for handling the restart waiting function

    sleep_interval=10 #how often to check if the service is still running
    max_wait="${MAX_WAIT_AMOUNT:-60}" #total time in seconds to allow the server process to exit
    max_attempt=$((max_wait/sleep_interval)) #used with the waitCounter to determine current attempts
    waitCounter=0

    echo "Waiting for FileMaker Server to stop...."
    while [[ $waitCounter -lt $max_attempt ]]; do
        isServerRunning || break
        printf "  ...waiting (%ds elapsed of %ds max) \n" $((waitCounter*sleep_interval)) "$max_wait"
        sleep $sleep_interval
        ((waitCounter++))
    done

    if isServerRunning; then
        echo "[WARNING] Filemaker Server did not stop within the expected $max_wait seconds."
        exit 1
    else
        echo "FileMaker Server stopped successfully."
    fi
    
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        service fmshelper start
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        launchctl start com.filemaker.fms
    fi
fi

echo "Lets Encrypt certificate request script completed without any errors."
