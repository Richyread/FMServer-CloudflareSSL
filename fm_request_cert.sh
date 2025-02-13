#!/usr/bin/env bash
set -u
set -o pipefail

# This script runs the certbot generation and imports the certificate into FileMaker Server. This script is required to be ran
# as root for initial validation and to permit access to FileMaker Server for certificate import. Please ensure that FileMaker
# Server is running prior to running this script.

# Usage:
# sudo -E ./fm_request_cert.sh

# Detects if FileMaker Server is still running
isServerRunning()
{
    fmserver=$(ps axc | sed "s/.*:..... /\"/" | sed s/$/\"/ | grep fmserver)
    if [[ -z $fmserver ]] ; then
        return 0    # fmserver is not running
    fi
    return 1        # fmserver is running
}

# Used to redirect errors to stderr
err()
{
    echo "$*" >&2
}

# Test to see if Certbot is installed
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    # Ubuntu
    if [[ ! -e "/snap/bin/certbot" ]] ; then
        err "[ERROR] Certbot not installed. Exiting..." 
        # Install Certbot Package
        # snap install --classic certbot
        # Prepare Certbot Command
        # ln -s /snap/bin/certbot /usr/bin/certbot
        exit 1
    fi
elif [[ "$OSTYPE" == "darwin"* ]]; then
	certbotLocation=$(command -v certbot)
	# Installation directory for Mac with Apple Silicon /opt/homebrew/bin/certbot
	# Installation directory for Intel-based Macs /usr/local/bin/certbot
    if [[ -z "$certbotLocation" ]] ; then
		err "[ERROR] Certbot not installed. Exiting..." 
		# Install Homebrew
		# /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
		# Prepare Homebrew
		# (echo; echo 'eval "$(/opt/homebrew/bin/brew shellenv)"') >> /Users/$USER/.zprofile
		# zsh
		# eval "$(/opt/homebrew/bin/brew shellenv)"
		# Install Certbot
		# brew install certbot
		exit 1
    fi
fi

PROMPT=0                                    # Set to 1 to get user prompts for script variables.
RESTART_SERVER=1                            # [WARNING]: If set to 1, will automatically restart server, without warning.
MAX_WAIT_AMOUNT=6                           # Used to determine max wait time for server to stop: time =  MAX_WAIT_AMOUNT * 10 seconds

#============================================
# Certbot Parameters
#============================================
DOMAIN="sample_domain.com"                  # Domain used to generate the certificate. When using multiple domains, separate them
                                            # with a comma. ie: sample_domain1.com,sample_domain2.com

EMAIL="sample_email@email.com"              # Email used to generate the certificate, will recieve reminders from Let's Encrypt
                                            # when the certificate generated is about to expire.

CFAPI_PATH=~/.secrets/certbot/cloudflare.ini #location of file storing the cloudflare API token from your account
TEST_CERTIFICATE=1                          # Set to 1, this will not use up a request and can be used as a dry-run to test. If 
                                            # Set to 0, the command will be run and will use up a certificate request.
UPDATE_EXISTING_CERT=1                      # Set if trying to update an existing cert, ie: adding an additional domain.

SECONDARY_MACHINE=0							# Set to 0, this script is being run on FileMaker Server Primary Machine, if 1: Secondary Machine

#============================================
#FMS Parameters
#============================================
FAC_USERNAME=usersomething
FAC_PASSWORD=passwordhere

# FileMaker Admin Console Login Information
if [ $PROMPT == 0 ] ; then
	if [ $SECONDARY_MACHINE == 0 ] ; then
		if [[ -n "${FAC_USERNAME}" ]]; then
			FAC_USER="${FAC_USERNAME}"
		else
			err " [ERROR]: The FileMaker Server Admin Console Credentials was not set. Set FAC_USERNAME as an environment variable using export FAC_USERNAME="
			err " If FAC_USERNAME and FAC_PASSWORD have been set, make sure to run the script using sudo -E ./fm_request_cert.sh"
			err " Additionally, make sure that to set FAC_PASSWORD as an environment variable using export FAC_PASSWORD="
			exit 1
		fi

		if [[ -n "${FAC_PASSWORD}" ]]; then
			FAC_PASS="${FAC_PASSWORD}"
		else
			err " [ERROR]: The FileMaker Server Admin Console Credentials was not set. Set FAC_PASSWORD as an environment variable using export FAC_PASSWORD="
			exit 1
		fi
	fi
else
    # Prompt user for values
    echo " Enter email for Let's Encrypt Notifications."
    read -p "   > Email: " EMAIL
    echo " Enter the domain for Certificate Generation. Note: Wildcards are not supported."
    read -p "   > Domain: " DOMAIN

	echo " Is this script being run for a Primary or Secondary Installation of FileMaker Server?"
    read -p "   > FileMaker Server Installation: (0 for Primary, 1 for Secondary): " SECONDARY_MACHINE

	if [ $SECONDARY_MACHINE == 0 ] ; then
		echo " To import the certificates and restart FileMaker Server, enter the FileMaker Admin Console credentials:"
		read -s -p "   > Username: " FAC_USER
		echo ""

		read -s -p "   > Password: " FAC_PASS
		echo ""
	fi

    echo " Do you want to restart FileMaker Server after the certificate is generated?"
    read -p "   > Restart (0 for no, 1 for yes): " RESTART_SERVER

    echo " Do you want to generate a test certificate?"
    read -p "   > Test Validation (0 for no, 1 for yes): " TEST_CERTIFICATE
fi

# DO NOT EDIT - FileMaker Directories
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    CERTBOTPATH="/opt/FileMaker/FileMaker Server/CStore/Certbot"
    # detect if use is using Apache
    if [[ -e "/opt/FileMaker/FileMaker\ Server/NginxServer/UseHttpd" ]] ; then
        WEBROOTPATH="/opt/FileMaker/FileMaker Server/HTTPServer/htdocs/"
    else
        # default path for NGINX
        WEBROOTPATH="/opt/FileMaker/FileMaker Server/NginxServer/htdocs/httpsRoot/"
    fi
elif [[ "$OSTYPE" == "darwin"* ]]; then
    CERTBOTPATH="/Library/FileMaker Server/CStore/Certbot"
    WEBROOTPATH="/Library/FileMaker Server/HTTPServer/htdocs/"
fi

# Set up paths for necessary directories
if [[ ! -e "$WEBROOTPATH" ]] ; then
    echo "[WARNING]: $WEBROOTPATH not found. Creating necessary directories." 
    mkdir -p "$WEBROOTPATH"
fi
if [[ ! -e "$CERTBOTPATH" ]] ; then
    echo "[WARNING]: $CERTBOTPATH not found. Creating necessary directories." 
    mkdir -p "$CERTBOTPATH"
fi

echo "- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -"

# Disggregate domain list into arguments
DOMAIN+=","
DOMAINLIST=""
IFS=',' read -ra ADDR <<< "$DOMAIN"
FIRST_DOMAIN=""
for CUR_DOMAIN in "${ADDR[@]}"; do
    if [[ -z "${FIRST_DOMAIN}" ]] ; then
        # First domain in list will be used for the name of the folder
        FIRST_DOMAIN=${CUR_DOMAIN}
    fi
    DOMAINLIST+="-d ${CUR_DOMAIN} "
done

# Check to see if a directory already exists for the domain
if [[ -e "$CERTBOTPATH/live/$FIRST_DOMAIN" ]] ; then 
    err "[ERROR]: A directory with the domain $FIRST_DOMAIN already exists. Please backup and remove the folder \"$CERTBOTPATH/live/$FIRST_DOMAIN/\""
    exit 1
fi 

# If updating current certificate (UPDATE_EXISTING_CERT) is set to 1
EXPAND_PARAM=""
if [[ $UPDATE_EXISTING_CERT -eq 1 ]] ; then
    EXPAND_PARAM=" --expand"
fi

# Test Parameter
TEST_CERT_PARAM=""
if [[ $TEST_CERTIFICATE -eq 1 ]] ; then
    TEST_CERT_PARAM=" --dry-run"
fi

if [[ $TEST_CERTIFICATE -eq 1 ]] ; then
    echo "Generating test certificate request." 
else
    echo "Generating certificate request." 
fi

# Ubuntu ONLY: Allow incoming connections into ufw
# Do not add unnecessary lines from here to the restarting ufw. 
#if [[ "$OSTYPE" == "linux-gnu"* ]]; then
#    service ufw stop
#fi

# Run the certbot certificate generation command
sudo -E certbot certonly --dns-cloudflare --dnscloudflare-credentials "$CFAPI_PATH" $TEST_CERT_PARAM $DOMAINLIST --agree-tos --non-interactive -m $EMAIL --config-dir "$CERTBOTPATH" --work-dir "$CERTBOTPATH" --logs-dir "$CERTBOTPATH"$EXPAND_PARAM

# Capture return code for running certbot command
RETVAL=$?

# Ubuntu ONLY: Restart ufw firewall
#if [[ "$OSTYPE" == "linux-gnu"* ]] ; then
#    service ufw start
#fi

if [ $RETVAL != 0 ] ; then
    err "[ERROR]: Certbot returned with a nonzero failure code. Check $CERTBOTPATH/letsencrypt.log for more information."
    exit 1
fi

# if we are testing, we don't need to import/restart
if [[ $TEST_CERTIFICATE -eq 1 ]] ; then
    exit 1
fi

PRIVKEYPATH=$(realpath "$CERTBOTPATH/live/$FIRST_DOMAIN/privkey.pem")
CERTFILEPATH=$(realpath "$CERTBOTPATH/live/$FIRST_DOMAIN/fullchain.pem")

# grant fmserver:fmsadmin group ownership
if [ -e "$CERTBOTPATH" ] ; then
    chown -R fmserver:fmsadmin "$CERTBOTPATH"
else
    err "[ERROR]: FileMaker Certbot folder was not found. Exiting..."
    exit 1
fi

if [ -f "$PRIVKEYPATH" ] ; then
    chown -R fmserver:fmsadmin "$PRIVKEYPATH"
else
    err "[ERROR]: An error occurred with certificate generation. No private key found."
    exit 1
fi

if [ -f "$CERTFILEPATH" ] ; then
    chown -R fmserver:fmsadmin "$CERTFILEPATH"
else
    err "[ERROR]: An error occurred with certificate generation. No certificate found."
    exit 1
fi

echo "- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -"

# import certificates
echo "Importing Certificates:"
echo "Certificate: $CERTFILEPATH"
echo "Private key: $PRIVKEYPATH"

fmsadmin certificate import "$CERTFILEPATH" --keyfile "$PRIVKEYPATH" -y -u $FAC_USER -p $FAC_PASS

# Capture return code for running certbot command
RETVAL=$?
if [ $RETVAL != 0 ] ; then
    err "[ERROR]: FileMaker Server was unable to import the generated certificate."
    exit 1
fi

# check if user wants to restart server
if [[ $RESTART_SERVER == 1 ]] ; then
    echo "- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -"
    echo "Restarting FileMaker Server."
    isServerRunning
    serverIsRunning=$?
    if [ $serverIsRunning -eq 1 ] ; then
        if [[ "$OSTYPE" == "linux-gnu"* ]]; then
            service fmshelper stop
        elif [[ "$OSTYPE" == "darwin"* ]]; then
            launchctl stop com.filemaker.fms
        fi
    fi

    waitCounter=0
    while [[ $waitCounter -lt $MAX_WAIT_AMOUNT ]] && [[ $serverIsRunning -eq 1 ]]
    do
        sleep 10
        isServerRunning
        serverIsRunning=$?
        echo "Waiting for FileMaker Server process to terminate..."

        waitCounter=$((waitCounter++))
    done

    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        service fmshelper start
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        launchctl start com.filemaker.fms
    fi
fi

# set up cronjob on MacOS for automatic renewal
if [[ "$OSTYPE" == "darwin"* ]]; then
    echo "Setting up cronjob for Certbot automatic renewal."
    echo "0 0,12 * * * root $(command -v python3) -c 'import random; import time; time.sleep(random.random() * 3600)' && sudo $(command -v certbot) renew -q" | sudo tee -a /etc/crontab > /dev/null
fi

echo "Lets Encrypt certificate request script completed without any errors."
