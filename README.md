## FileMaker_Server-CloudflareSSL - Steps to Generate an SSL Certificate on a New Server using LetsEncrypt service
--------

Workspace to house scripts for generating SSL Certificates for FileMaker Server instances.

> **Scope note.** This repo started SSL-only and has grown a second role: it also carries the small **fleet monitoring** scripts behind the healthchecks.io watchdog — `cert_expiry_healthcheck.sh` (certificate expiry) and `hc-heartbeat.sh` (box heartbeat). The heartbeat is deliberately generic and is installed on boxes running no FileMaker at all (PBS, unRAID). The repo name is kept as-is because it is baked into the install URLs below and into the runbooks that use them.

Scripts modified from source provided by Claris as part of the standard installation contained in '/opt/FileMaker/FileMaker Server/Tools/Lets_Encrypt

Primary modifications are to enable request & renewal of certificates via 'DNS-01 Challenge' rather than the 'HTTP-01 Challenge' which is currently the default (and only) option.

Whilst the changes are for Cloudflare specific dns-challenges, similar steps could be followed to substitute in any of the other providers etc. View the Certbot main documentation for DNS Plugins and subsequent tweaks required for each specific dns provider. In the example of Cloudflare you need to obtain an API token from your account and pass this through to the script via a 'cloudflare.ini' file.

## Initial setup and Cloudflare API token ##

Become root & install Certbot package and set command links:

```
sudo -i

snap install --classic certbot && \
ln -s /snap/bin/certbot /usr/bin/certbot

```

Update Certbot permissions and install the dns-cloudflare plugin:

```

snap set certbot trust-plugin-with-root=ok
snap install certbot-dns-cloudflare

```

Create the required Cloudflare.ini file for storing the API key:

```

mkdir -p /root/.secrets/certbot/ && \
cd /root/.secrets/certbot/ && \
curl -sSL https://raw.githubusercontent.com/Richyread/FMServer-CloudflareSSL/main/cloudflare.ini -o cloudflare.ini && \
nano cloudflare.ini


```

Edit the downloaded cloudflare.ini file by pasting in a valid Cloudflare API token from your Cloudflare account.

> The token needs **Zone → DNS → Edit** (plus **Zone → Read**) permission for the relevant zone so that Certbot can create and remove the `_acme-challenge` TXT record during the DNS-01 challenge. A scoped API token is preferred over a global API key.

Once updated we need to secure the directory & file permissions correctly or Certbot will present an error on use.

```

chmod 700 /root/.secrets && \
chmod 700 /root/.secrets/certbot && \
chmod 600 /root/.secrets/certbot/cloudflare.ini

```

## Generate .env file & populate variables ##

Run the following commands to:
 - Navigate to the LetsEncrypt directory
 - Download the example_env.md template and save it as '.env' file
 - Set temporary permissions for easy editing

```
cd "/opt/FileMaker/FileMaker Server/Tools/Lets_Encrypt" && \
curl -sSL https://raw.githubusercontent.com/Richyread/FMServer-CloudflareSSL/main/example_env.md -o .env && \
chmod 666 .env

nano .env
```

Go through the .env and adjust the variables for the target machine as required. Ensure you insert real values for Domain, Email etc.

Once editing is completed save the file then ensure you correctly reset the permissions to restrict access:

```

chmod 600 .env

```

## Remove existing 'HTTPS-01' default scripts & recreate ##

Use the commands below to:
  - remove the two default installed 'HTTPS-01' challenge scripts
  - download the revised 'DNS-01' challenge scripts from github repo
  - set correct ownership and permissions

```
rm -f fm_{request,renew}_cert.sh && \
curl -sSL https://raw.githubusercontent.com/Richyread/FMServer-CloudflareSSL/main/fm_request_cert.sh -o fm_request_cert.sh && \
curl -sSL https://raw.githubusercontent.com/Richyread/FMServer-CloudflareSSL/main/fm_renew_cert.sh -o fm_renew_cert.sh
    
```

```
chown fmserver:fmsadmin fm_{request,renew}_cert.sh && sudo chmod 755 fm_{request,renew}_cert.sh

```    
## Generate a certificate ##

Run the request script once on each new machine to:
 - Create a certificate store on the machine
 - Generate the certificate request and process via the Lets Encrypt service
 - Store the generated certificate files
 - Upload to FileMaker Server and restart (if specified in the .env variable)

```
exit
sudo -E ./fm_request_cert.sh
```


You should receive either a "Testing successful" or a "Certificate Produced" message upon completion. Process takes around 30secs and should save any error messages to the log files located in /opt/FileMaker/FileMaker Server/Tools/Lets_Encrypt/letsencrypt.log

## Renewing a certificate ##

Let's Encrypt certificates are valid for 90 days. Because these scripts issue the certificate into a custom Certbot `--config-dir` (under FileMaker Server's `CStore/Certbot`), **Certbot's built-in snap auto-renew timer cannot see them** — so renewal is a manual step (run it when you are within ~2-3 weeks of expiry, or drive it from a reminder/monitor):

```
cd "/opt/FileMaker/FileMaker Server/Tools/Lets_Encrypt"
sudo -E ./fm_renew_cert.sh
```

The renewal script renews via the DNS-01 challenge, imports the new certificate into FileMaker Server, restarts the service, and then **verifies on the wire that port 443 is actually serving the new certificate** (guarding against the "cert imported but old cert still served" failure mode). Set `FORCE_RENEW=1` in `.env` to renew even when the certificate is not yet within Certbot's 30-day renewal window (useful for testing).

> **After any FileMaker Server upgrade**, re-verify that the DNS-01 scripts in `Tools/Lets_Encrypt/` were not overwritten by Claris's default HTTP-01 versions — a server upgrade can restore the stock scripts. Re-download from this repo if needed.

## Monitoring certificate expiry (healthchecks.io reminder) ##

Because these certificates renew **manually** (see above), the safety net is a reminder that nags you when one is approaching expiry. `cert_expiry_healthcheck.sh` provides this using [healthchecks.io](https://healthchecks.io) as an external dead-man's-switch.

**How it works — active probe, not ping-on-renewal.** A daily cron reads the *live* certificate expiry straight off the wire (`openssl s_client`) and pings a healthchecks.io check **only while more than `THRESHOLD_DAYS` (default 14) remain**. When the certificate nears expiry — **or** a renewal has silently failed, **or** the certificate can't be read at all — the ping is withheld, so healthchecks.io alerts after its grace window. That means the alert tracks the *real* cert state on the wire rather than trusting a human to remember to ping on a successful renewal (these certs have lapsed under manual handling before, which is exactly why the probe is state-based).

> **Public repo — never commit a real ping URL.** A healthchecks.io ping URL is a secret: anyone who has it can spoof a healthy ping and suppress your alert. The `CERTS` line in this repo copy must keep its generic `CERT_FQDN_HERE` / `PASTE_HEALTHCHECKS_PING_URL_HERE` placeholders. Put the real domain and ping URL only in the copy installed on each server.

**Set-up (per server):**

1. In healthchecks.io, create one check per certificate this box serves — schedule type **Period = 1 day, Grace = 3 days** (so ~4 days of silence raises the alert, i.e. it fires at roughly 10 days-to-expiry). Wire the check to your notification channel(s).
2. Install the script to a clean path and edit its `CERTS` line for this box's domain(s) + the check's ping URL:

```
sudo curl -sSL https://raw.githubusercontent.com/Richyread/FMServer-CloudflareSSL/main/cert_expiry_healthcheck.sh -o /usr/local/sbin/cert_expiry_healthcheck.sh
sudo chmod 755 /usr/local/sbin/cert_expiry_healthcheck.sh
sudo nano /usr/local/sbin/cert_expiry_healthcheck.sh
```

The `CERTS` array takes one `"FQDN:port|PING_URL"` entry per certificate, where `PING_URL` is the full healthchecks.io URL pasted exactly as copied — probe each box against **its own** `:443` so you check the exact certificate being served (this avoids split-horizon DNS resolving the name to a different front-end/cert).

3. Add a daily cron entry and test once (the check should flip green):

```
echo '23 7 * * * root /usr/local/sbin/cert_expiry_healthcheck.sh' | sudo tee /etc/cron.d/cert-healthcheck
sudo /usr/local/sbin/cert_expiry_healthcheck.sh && journalctl -t cert-healthcheck -n 5
```

`THRESHOLD_DAYS` in the script controls how much lead time you get before the reminder trips; raise it for a longer runway.

## Box heartbeat (healthchecks.io) ##

`hc-heartbeat.sh` is the other half of the same watchdog: a daily "I'm alive" ping so that a box which goes **silently** offline is noticed. It is generic and belongs on every box in the fleet, FileMaker or not.

**What it proves:** the box is powered and has outbound internet.
**What it does not prove:** tailnet health, or that any backup job ran — those are the job success-pings, which are separate checks.

> **A cert check does NOT double as a heartbeat.** The two run different grace windows on purpose: the cert probe uses Grace **3d** so a manual DNS-01 renewal has lead time, while a heartbeat uses Grace **1d** so an outage surfaces in ~48h. The 3d grace cannot be tightened without reintroducing false cert alarms, so one check cannot serve both latencies. Boxes running both scripts need both checks.

> **Public repo — never commit a real ping URL.** As with the cert script, the `PING_URL` line in this repo copy must keep its `PASTE_HEALTHCHECKS_PING_URL_HERE` placeholder. The script refuses to run while the placeholder is still in place, rather than silently pinging nothing.

**Set-up (per box):**

1. In healthchecks.io, create one check for this box — name it `Heartbeat: <box>` using the **tailnet** name, schedule type **Period = 1 day, Grace = 1 day**. Wire it to your notification channel(s).
2. Install the script and paste this box's ping URL into it:

```
sudo curl -sSL https://raw.githubusercontent.com/Richyread/FMServer-CloudflareSSL/main/hc-heartbeat.sh -o /usr/local/sbin/hc-heartbeat.sh
sudo chmod 700 /usr/local/sbin/hc-heartbeat.sh
sudo nano /usr/local/sbin/hc-heartbeat.sh
```

Mode **700** rather than 755: the file holds a ping URL, and anyone holding one can spoof a healthy ping and suppress the alert.

3. Add the daily cron stub and test once (the check should flip green):

```
echo '30 7 * * * root /usr/local/sbin/hc-heartbeat.sh' | sudo tee /etc/cron.d/hc-heartbeat
sudo /usr/local/sbin/hc-heartbeat.sh && journalctl -t hc-heartbeat -n 5
```

> **Verify cron accepted the file, not just that the file exists.** A `/etc/cron.d/` entry with any syntax error is discarded **silently and in its entirety** — and because the manual test above turns the check green, healthchecks.io will look correct while nothing is scheduled. Confirm with `journalctl -u cron -n 20`, which should log a `RELOAD` for the file and no `Error: bad minute`. The most common cause is a pasted comment line wrapping into a second line that cron then reads as a broken schedule; keep every line in `/etc/cron.d/` short.


---------------------------------

***Some tips/error resolutions***
  
- Enable the scripts to be executable by using command ``` sudo chmod +x {name of script} ```

- Change ownership of files by using ``` sudo chown user:group {name of file/directory} ```

- Change file privileges to owner only ``` sudo chmod 700 {file/directory} ```

- Change file privileges to read/write for all users ``` sudo chmod 755 {file/directory} ```
