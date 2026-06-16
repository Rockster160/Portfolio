#!/bin/sh
# Certbot post-renewal hook for the Tesla fleet-telemetry server.
# Restarts fleet-telemetry so the new cert is picked up.
# Install at /etc/letsencrypt/renewal-hooks/deploy/restart-fleet-telemetry.sh
set -e
systemctl restart fleet-telemetry.service
