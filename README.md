# FileMaker_Server-CloudflareSSL

Workspace to house scripts for generating SSL Certificates for FileMaker Server instances.

Scripts modified from source provided by Claris as part of the standard installation contained in '/opt/FileMaker/FileMaker Server/Tools/Lets_Encrypt

Primary modifications are to enable request & renewal of certificates via 'DNS-01 Challenge' rather than the 'HTTP-01 Challenge' which is currently the default (and only) option.

Whilst the changes are for Cloudflare specific dns-challenges, similar steps could be followed to substitue in any of the other providers etc. View the Certbot main documentation for DNS Plugins and subsequent tweaks required for each specific dns provider. In the example of Cloudflare you need to obtain an API key from your account and pass this through to the script via an 'cloudflare.ini' file.

## Steps to Generate SSL Certificates On A New Server ##

1. Copy the commands from [Initial_setup.sh] onto target machine to install Certbot and supporting files
2. Edit the empty cloudflare.ini file by pasting in a valid Cloudflare API key generated from your account
3. Adjust permissions on the cloudflare.ini file using command [chmod 600 ~/.secrets/certbot/cloudflare.ini
4. Navigate/CD to '/opt/FileMaker/FileMaker Server/Tools/Lets_Encrypt
5. Create an empty .env file with the following command [sudo touch .env] and then open the file for editing with the command [sudo nano .env]
6. Using the template [example_env.md] populate the .env file with the required details, adjusting the variables for the target machine as required
7. Change the permissions on the .env file to restrict access using command [sudo chmod 600 .env]
8. Use the command [sudo rm fm_request_cert.sh && sudo rm fm_renew_cert.sh] to remove the two default installed 'HTTPS-01' challenge scripts.
9. Use the command [sudo touch fm_request_cert.sh && sudo touch fm_renew_cert.sh] to create new blank script files
10. Use the command [sudo chmod 777 fm_request_cert.sh && sudo chmod 777 fm_renew_cert.sh] to temporarily enable editing & saving in VSCode etc.
11. Update the scripts to use the DNS-01 logic from the repo
12. Once the scripts have been updated, ensure the ownership of each file is correctly set and the permissions are revised to owner only

13. Save changes and run the updated script by using the command [sudo -E ./<name of script>] and entering the sudo password when requested.
14. Depending on the value set on {Line 71} you should recieve either a "Testing successful" or a "Certificate Produced" message on completion. Process takes about 30secs and should save any error messages to the log files located in [/opt/FileMaker/FileMaker Server/Tools/Lets_Encrypt/letsencrypt.log



****Some tips/error resolutions***
  
- Enable the scripts to be executable by using command [sudo chmod +x {name of script}]

- Change ownership of files by using [sudo chown user:group {name of file/directory}]

- Change file priveleges to owner only [sudo chmod 700 {file/directory}]

- Change file privelges to read/write for all users [sudo chmod 755 {file/directory}]
