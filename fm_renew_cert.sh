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

#Changes:
# 23 May 2025
# - adjusted script to reference '.env' file for variables
# - removed hardcoded values for login details and domain name etc
# - removed sections for user prompts (script will run autonomously using values in .env)
# - removed remaining sections reffering to the HTTP-01 Challenge such as $WEBROOTPATH

#================================================================================

#-----------------------------------
# Load configuration from .env file
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
    local fmserver
    fmserver=$(ps axc | awk '/fmserver/ {print $1}')
    if [[ -z "$fmserver" ]]; then
        return 0    # fmserver not running
    else
        return 1    # fmserver is tunning
    fi
}

err() {
    echo "$*" >&2
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

if [[ "$TEST_CERTIFICATE" == "1" ]]; then
    certbot renew --dry-run --cert-name "$DOMAIN" -w "$WEBROOTPATH" \
        --config-dir "$CERTBOTPATH" --work-dir "$CERTBOTPATH" --logs-dir "$CERTBOTPATH"
else
    if [[ "$FORCE_RENEW" == "1" ]]; then
        certbot renew --cert-name "$DOMAIN" --force-renew \
            --config-dir "$CERTBOTPATH" --work-dir "$CERTBOTPATH" --logs-dir "$CERTBOTPATH"
    else
        certbot renew --cert-name "$DOMAIN" \
            --config-dir "$CERTBOTPATH" --work-dir "$CERTBOTPATH" --logs-dir "$CERTBOTPATH"
    fi
fi

RETVAL=$?
if [[ $RETVAL -ne 0 ]]; then
    err "[ERROR] Certbot renewal failed. Check logs in $CERTBOTPATH/letsencrypt.log"
    exit 1
fi

#-----------------------------------
# Import certificate into FileMaker Server
#-----------------------------------

CERTFILEPATH=$(realpath "$CERTBOTPATH/live/$DOMAIN/fullchain.pem")
PRIVKEYPATH=$(realpath "$CERTBOTPATH/live/$DOMAIN/privkey.pem")

# Check certificate files exist
if [[ ! -f "$CERTFILEPATH" || ! -f "$PRIVKEYPATH" ]]; then
    err "[ERROR] Missing certificate or private key files after renewal."
    exit 1
fi

chown -R fmserver:fmsadmin "$CERTFILEPATH" "$PRIVKEYPATH"

echo "Importing renewed certificate into FileMaker Server..."
fmsadmin certificate import "$CERTFILEPATH" --keyfile "$PRIVKEYPATH" -y -u "$FAC_USERNAME" -p "$FAC_PASSWORD"
if [[ $? -ne 0 ]]; then
    err "[ERROR] Failed to import certificate into FileMaker Server."
    exit 1
fi

#-----------------------------------
# Optionally restart the FileMaker Server
#-----------------------------------

if [[ "$RESTART_SERVER" == "1" ]]; then
    echo "Restarting FileMaker Server to apply changes..."
    isServerRunning
    if [[ $? -eq 1 ]]; then
        if [[ "$OSTYPE" == "linux-gnu"* ]]; then
            service fmshelper stop
        else
            launchctl stop com.filemaker.fms
        fi
    fi

    waitCounter=0
    MAX_WAIT=${MAX_WAIT_AMOUNT:-6}
    while [[ $waitCounter -lt $MAX_WAIT ]]; do
        sleep 10
        isServerRunning
        [[ $? -eq 0 ]] && break
        echo "Waiting for FileMaker Server to stop..."
        ((waitCounter++))
    done

    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        service fmshelper start
    else
        launchctl start com.filemaker.fms
    fi
fi

echo "Certificate renewal and import completed successfully."
