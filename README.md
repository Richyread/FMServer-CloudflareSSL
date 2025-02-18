# FileMaker_Server-CloudflareSSL

Workspace to house scripts for generating SSL Certificates for FileMaker Server instances.

Scripts modified from source provided by Claris as part of the standard installation contained in '/opt/FileMaker/FileMaker Server/Tools/Lets_Encrypt

Primary modifications are to enable request & renewal of certificates via 'DNS-challenge' rather than the 'HTTP-challenge' which is currently the default (and only) option.

Whilst the changes are for Cloudflare specific dns-challenges, similar steps could be followed to substitue in any of the other providers etc. View the Certbot main documentation for DNS Plugins and subsequent tweaks required for each specific dns provider. In the example of Cloudflare you need to obtain an API key from your account and pass this through to the script via an 'cloudflare.ini' file.

## Steps to Generate SSL Certificates On A New Server ##

1. Copy the commands from [Initial_setup.sh] onto target machine to install Certbot and supporting files
2. Edit the empty cloudflare.ini file by pasting in a valid Cloudflare API key generated from your account
3. Adjust permissions on the cloudflare.ini file using command [chmod 600 ~/.secrets/certbot/cloudflare.ini
4. Navigate to '/opt/FileMaker/FileMaker Server/Tools/Lets_Encrypt
5. Edit the script [fm_request_cert.sh] to provide the following details:
   
   1. {Line 64} Add FQDN to be used for requested certificate
   2. {Line 67} Add valid email address to receive alerts and assign requests against
   3. {Line 71} Set value =0 for Production certificate
   4. {Line 80} Add valid server Admin Console user account to allow for certificate upload
   5. {Line 81} Add valid server Admin Console user password to allow for certificate upload
   
9. Save changes and run the updated script by using the command [sudo -E ./fm_request_cert.sh] and entering the sudo password when requested.
10. Depending on the value set on {Line 71} you should recieve either a "Testing successful" or a "Certificate Produced" message on completion. Process takes about 30secs and should save any error messages to the log files located in [/opt/FileMaker/FileMaker Server/Tools/Lets_Encrypt/letsencrypt.log



****Some tips/error resolutions***
  
- Enable the scripts to be executable by using command [sudo chmod +x {name of script}]

- Change ownership of files by using [sudo chown user:group {name of file/directory}]

- Change file priveleges to owner only [sudo chmod 700 {file/directory}]

- Change file privelges to read/write for all users [sudo chmod 755 {file/directory}]
