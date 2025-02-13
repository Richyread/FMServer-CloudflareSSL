# FileMaker_Server-CloudflareSSL

Workspace to house scripts for generating SSL Certificates for FileMaker Server instances.

Scripts modified from source provided by Claris as part of the standard installation contained in '/opt/FileMaker/FileMaker Server/Tools/Lets_Encrypt

Primary modifications are to enable request & renewal of certificates via 'DNS-challenge' rather than the 'HTTP-challenge' which is currently the default (and only) option.

Whilst the changes are for Cloudflare specific dns-challenges, similar steps could be followed to substitue in any of the other providers etc. View the Certbot main documentation for DNS Plugins and subsequent tweaks required for each specific dns provider. In the example of Cloudflare you need to obtain an API key from your account and pass this through to the script via an 'cloudflare.ini' file.

## Steps to Generate SSL Certificates On A New Server ##

1. Create a working directory underneath the defualt 'home' directory on Ubuntu Sever. E.g. ~./certbot
2. Clone this repository into this new directory so as to have copies of the modified scripts on the target machine.
3. Enable the scripts to be executable by using command [sudo chmod +x {name of script}]
4. Edit the cloudflare.ini file by pasting in the Cloudflare API key.
5. Adjust permissions on the cloudflare.ini file using command [chmod 600 ~/.secrets/certbot/cloudflare.ini
6. Edit the sctipt [fm_request_cert.sh] to provide the following details:
   
   1. {Line 64} Add FQDN to be used for requested certificate
   2. {Line 67} Add valid email address to receive alerts and assign requests against
   3. {Line 71} Set value =1 for Testing and value =0 for Production certificate
   4. {Line 80} Add valid server Admin Console user account to allow for certificate upload
   5. {Line 81} Add valid server Admin Console user password to allow for certificate upload
   
8. Save changes and run the updated script by using the command [./fm_request_cert.sh] and entering the sudo password when requested.
9. Depending on the value set on {Line 71} you should recieve either a "Testing successful" or a "Certificate Produced" message on completion. Process takes about 30secs and should save any error messages to the log files located in [/opt/FileMaker/FileMaker Server/Tools/Lets_Encrypt/letsencrypt.log
