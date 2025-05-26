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
        err "[ERROR] Certbot not installed. Please install Certbot and run fm_request_cert.sh first. Exiting..."
        exit 1
    fi
elif [[ "$OSTYPE" == "darwin"* ]]; then
    if ! command -v certbot &> /dev/null; then
        err "[ERROR] Certbot not installed. Please install Certbot and run fm_request_cert.sh first. Exiting"
        exit 1
    fi
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
elif [[ "$OSTYPE" == "darwin"* ]]; then
    CERTBOTPATH="/Library/FileMaker Server/CStore/Certbot"
fi


#-----------------------------------
# Verify certificate path exists
#-----------------------------------

if [[ ! -d "$CERTBOTPATH" ]]; then
    err "[ERROR] Certificate directory not found at $CERTBOTPATH"
    exit 1
fi


#-----------------------------------
# Certbot Renew Certificate
#-----------------------------------

echo "Running Certbot renewal for domain: $DOMAIN"

CERTBOT_ARGS=(
    renew
    --cert-name "$DOMAIN"
    --config-dir "$CERTBOTPATH"
    --work-dir "$CERTBOTPATH"
    --logs-dir "$CERTBOTPATH"
)

# Optional: add --dry-run for testing
if [[ "${TEST_CERTIFICATE:-0}" == "1" ]]; then
    CERTBOT_ARGS+=(--dry-run)
fi

# Optional add --force-renew to always renew even if it is not expired

if [[ "${FORCE_RENEW:-0}" =="1" ]]; then
    CERTBOT_ARGS+=(--force-renew)
fi

"$CERTBOT_CMD" "${CERTBOT_ARGS[@]}"
RETVAL=$?

if [[ $RETVAL -ne 0 ]]; then
    echo "[ERROR] Certbot renewal failed. Check logs in $CERTBOTPATH/letsencrypt.log"
    exit 1
fi

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