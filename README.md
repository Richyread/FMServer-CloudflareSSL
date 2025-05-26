## FileMaker_Server-CloudflareSSL - Steps to Generate an SSL Certificate on a New Server using LetsEncrypt service
--------

Workspace to house scripts for generating SSL Certificates for FileMaker Server instances.

Scripts modified from source provided by Claris as part of the standard installation contained in '/opt/FileMaker/FileMaker Server/Tools/Lets_Encrypt

Primary modifications are to enable request & renewal of certificates via 'DNS-01 Challenge' rather than the 'HTTP-01 Challenge' which is currently the default (and only) option.

Whilst the changes are for Cloudflare specific dns-challenges, similar steps could be followed to substitue in any of the other providers etc. View the Certbot main documentation for DNS Plugins and subsequent tweaks required for each specific dns provider. In the example of Cloudflare you need to obtain an API key from your account and pass this through to the script via an 'cloudflare.ini' file.

## Initital setup and Cloudflare API key ##

Install Certbot package and set command links:

```

sudo snap install --classic certbot && \
sudo ln -s /snap/bin/certbot /usr/bin/certbot

```

Update Certbot permissions and install the dns-cloudflare plugin:

```

sudo snap set certbot trust-plugin-with-root=ok
sudo snap install certbot-dns-cloudflare

```

Create the required Cloudflare.ini file for storing the API key:

```

mkdir -p ~/.secrets/certbot/ && \
sudo curl -sSL https://raw.githubusercontent.com/Richyread/FMServer-CloudflareSSL/main/cloudflare.ini -o cloudflare.ini
sudo nano cloudflare.ini

```

Edit the downloaded cloudflare.ini file by pasting in a valid Cloudflare API key from your Cloudflare account.

The file should already have the correct 'root:root' and 'chmod 600' permissions & ownership values, but double check as the Certbot command will fail otherwise.


## Generate .env file & populate variables ##

Run the following commands to:
 - Navigate to the LetsEncrypt directory
 - Download the example_env.md template and save it as '.env' file
 - Set temporary permissions for easy editing

```
cd "/opt/FileMaker/FileMaker Server/Tools/Lets_Encrypt" && \
sudo curl -sSL https://raw.githubusercontent.com/Richyread/FMServer-CloudflareSSL/main/example_env.md -o .env && \
sudo chmod 666 .env
```

Go through the .env and adjust the variables for the target machine as required. Ensure you insert real values for Domain, Email etc.

Once editing is completed, ensure you change the permissions on the .env file to restrict access using command [sudo chmod 600 .env]

## Remove existing 'HTTPS-01' default scripts & recreate ##

Use the commands below command to:
  - remove the two default installed 'HTTPS-01' challenge scripts
  - download the revised 'DNS-01' challenge scripts from github repo
  - set correct ownership and permissions

```
sudo rm -f fm_{request,renew}_cert.sh && \
sudo curl -sSL https://raw.githubusercontent.com/Richyread/FMServer-CloudflareSSL/main/fm_request_cert.sh -o fm_request_cert.sh && \
sudo curl -sSL https://raw.githubusercontent.com/Richyread/FMServer-CloudflareSSL/main/fm_renew_cert.sh -o fm_renew_cert.sh
    
```

```
sudo chown fmserver:fmsadmin fm_{request,renew}_cert.sh && sudo chmod 755 fm_{request,renew}_cert.sh

```    
## Generate a certificate ##

Run the request script once on each new machine to:
 - Create a certificate store on the machine
 - Generate the certificate request and process via the Lets Encrypt service
 - Store the generated certificate files
 - Upload to FileMaker Server and restart (if specified in the .env variable)

```
sudo -E ./fm_request_cert.sh]
```


You should recieve either a "Testing successful" or a "Certificate Produced" message upon completion. Process takes around 30secs and should save any error messages to the log files located in /opt/FileMaker/FileMaker Server/Tools/Lets_Encrypt/letsencrypt.log


---------------------------------

***Some tips/error resolutions***
  
- Enable the scripts to be executable by using command ``` sudo chmod +x {name of script} ```

- Change ownership of files by using ``` sudo chown user:group {name of file/directory} ```

- Change file priveleges to owner only ``` sudo chmod 700 {file/directory} ```

- Change file privelges to read/write for all users ``` sudo chmod 755 {file/directory} ```
