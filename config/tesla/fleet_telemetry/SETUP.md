# Fleet Telemetry — Prod Setup

What this stack does:

```
Car → ardesian.com:4443 (TLS protobuf)
    → fleet-telemetry binary           (systemd service: fleet-telemetry)
    → JSON records on stdout
    → /var/log/tesla-telemetry/feed.jsonl
    → tail -F in Ruby bridge           (systemd service: tesla-telemetry-bridge)
    → POST http://localhost:3141/webhooks/tesla_telemetry
    → TeslaTelemetry.process → broadcast → TeslaChannel
```

Two systemd services, one Tesla Go binary, one Ruby tail bridge. LE cert is reused (auto-renewed by certbot, picked up by a renewal hook that restarts fleet-telemetry).

---

## One-time install (per server)

### 1. Install Go (1.21+)

Ubuntu 20.04's apt `golang-go` is too old (1.13–1.18) for current fleet-telemetry.

```bash
# Preferred: snap
sudo snap install go --classic

# OR upstream tarball if snap is unavailable
cd /tmp
curl -LO https://go.dev/dl/go1.22.5.linux-amd64.tar.gz
sudo rm -rf /usr/local/go && sudo tar -C /usr/local -xzf go1.22.5.linux-amd64.tar.gz
echo 'export PATH=$PATH:/usr/local/go/bin' | sudo tee /etc/profile.d/go.sh
source /etc/profile.d/go.sh

go version   # confirm 1.21+
```

### 2. Build the fleet-telemetry binary

fleet-telemetry imports `pebbe/zmq4` (Go bindings for libzmq) for the ZMQ
dispatcher option. The native library is required to build even when ZMQ
isn't used as a dispatcher.

```bash
sudo apt-get install -y libzmq3-dev pkg-config
```

Clone source into `/opt/fleet-telemetry/src/` (persistent — survives reboots, ready for `git pull` to update). Build as your user so Go's module cache lives in `$HOME/go`:

```bash
sudo mkdir -p /opt/fleet-telemetry
sudo chown rocco:rocco /opt/fleet-telemetry
git clone https://github.com/teslamotors/fleet-telemetry /opt/fleet-telemetry/src
cd /opt/fleet-telemetry/src
go build -o /opt/fleet-telemetry/fleet-telemetry ./cmd
```

### 3. Config + log dirs

```bash
sudo mkdir -p /etc/tesla /var/log/tesla-telemetry
sudo cp /var/www/portfolio/current/config/tesla/fleet_telemetry/config.yaml \
       /etc/tesla/fleet-telemetry.yaml
sudo chown rocco:rocco /var/log/tesla-telemetry
```

### 4. LE cert access

The fleet-telemetry process runs as `rocco` and needs to read the LE private key. Grant via the `ssl-cert` group:

```bash
sudo groupadd -f ssl-cert
sudo usermod -aG ssl-cert rocco
sudo chgrp -R ssl-cert /etc/letsencrypt/live /etc/letsencrypt/archive
sudo chmod -R g+rX     /etc/letsencrypt/live /etc/letsencrypt/archive
```

Log out + back in so the group membership takes effect.

### 5. Install the systemd units

```bash
cd /var/www/portfolio/current
sudo cp config/tesla/fleet_telemetry/systemd/fleet-telemetry.service        /etc/systemd/system/
sudo cp config/tesla/fleet_telemetry/systemd/tesla-telemetry-bridge.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now fleet-telemetry tesla-telemetry-bridge
```

### 6. LE renewal hook (so cert refreshes pick up automatically)

```bash
sudo cp config/tesla/fleet_telemetry/systemd/letsencrypt-restart.sh \
        /etc/letsencrypt/renewal-hooks/deploy/restart-fleet-telemetry.sh
sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/restart-fleet-telemetry.sh
```

### 7. Open port 4443 (if a firewall is added later)

UFW is currently inactive. If you enable it:

```bash
sudo ufw allow 4443/tcp comment "Tesla fleet-telemetry"
```

Also confirm the DigitalOcean Cloud Firewall (if any) allows TCP/4443.

### 8. Register with Tesla

From any console (uses the existing wizard or a one-liner):

```ruby
Oauth::TeslaApi.me.request_telemetry
```

---

## Day-to-day management

```bash
# Status
sudo systemctl status fleet-telemetry tesla-telemetry-bridge

# Tail the live record feed (raw JSON from Tesla)
tail -F /var/log/tesla-telemetry/feed.jsonl

# Tail fleet-telemetry's runtime logs (startup, errors)
sudo journalctl -u fleet-telemetry -f

# Tail the bridge's stdout (forwarding errors etc.)
sudo journalctl -u tesla-telemetry-bridge -f

# Restart everything after a code update
sudo systemctl restart fleet-telemetry tesla-telemetry-bridge
```

## Log rotation

`/var/log/tesla-telemetry/feed.jsonl` grows over time. Add `/etc/logrotate.d/tesla-telemetry`:

```
/var/log/tesla-telemetry/feed.jsonl {
    daily
    rotate 7
    compress
    missingok
    notifempty
    copytruncate
}
```

`copytruncate` is important — without it, fleet-telemetry's open file handle keeps writing to the rotated file, and the bridge keeps reading from it. With `copytruncate`, the file is truncated in place; both processes keep their handles valid.

## Updating the fleet-telemetry binary

```bash
cd /opt/fleet-telemetry/src
git pull
go build -o /opt/fleet-telemetry/fleet-telemetry ./cmd
sudo systemctl restart fleet-telemetry
```

## Moving to a new server

The minimum reproducible setup is steps 1–7 above plus:
- Same domain on the new server with its own LE cert
- Same Rails deploy at `/var/www/portfolio/current`
- Re-run `Oauth::TeslaApi.me.request_telemetry` to point Tesla at the new server

## Troubleshooting

- **`systemctl status fleet-telemetry` shows permission errors on the cert** — group membership didn't take effect; log out and back in, or `newgrp ssl-cert`.
- **`feed.jsonl` is empty after car drives** — confirm `request_telemetry` ran successfully and Tesla returned `{success: true}`. Try `Oauth::TeslaApi.me.check_telemetry` to see Tesla's stored config.
- **Bridge logs "POST failed: ECONNREFUSED"** — Rails isn't running on 3141 yet.
- **Bridge logs "webhook 403"** — the controller's `request.local?` guard is rejecting the bridge's POST. Confirm the bridge POSTs to `localhost:3141` (not a public IP).
- **TLS handshake errors in fleet-telemetry log** — Tesla can't validate the server cert. If using LE certs, verify the LE chain is intact: `openssl s_client -connect ardesian.com:4443 -showcerts`.
