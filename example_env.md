## Edit this file to update variables for each specific server.
## The file should then be saved as/renamed '.env' no filename and no extension etc.
## Ensure the variables are updated or adjusted to defulats appropriate for the specific server
## Text values (like email address) should be contained in quotes


# FileMaker Server SSL Certificate Request Config

# Primary domain for the SSL certificate (comma-separated list for multiple domains)
DOMAIN=" ~site name goes here~ "

# Email for Let's Encrypt expiration notifications
EMAIL=" ~email address for notifications goes here~ "

# Cloudflare API credentials file
CFAPI_PATH="/root/.secrets/certbot/cloudflare.ini"

# Admin Console credentials for FileMaker Server
FAC_USERNAME=" ~admin user~ "
FAC_PASSWORD=" ~admin password~ "

# Whether this is a secondary machine (0 = Primary, 1 = Secondary)
SECONDARY_MACHINE=0

# Whether to request a test certificate (0 = No, 1 = Yes)
TEST_CERTIFICATE=0

# Whether to expand/replace an existing certificate (0 = No, 1 = Yes)
UPDATE_EXISTING_CERT=1

# Whether to automatically restart FileMaker Server (0 = No, 1 = Yes)
RESTART_SERVER=1

# Max wait time in seconds to allow for FM server to stop running (MAX_WAIT_AMOUNT x 10)
MAX_WAIT_AMOUNT=6

# Whether to forcibly renew the certificate even if it is not needed. (0 = No, 1 = Yes)
FORCE_RENEW=0