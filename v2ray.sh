#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "ERROR: Run this script as root."
    exit 1
fi

BACKUP_MODE=0
OLD_SERVER=""
DOMAIN=""
SSL_URL=""

show_menu() {
    echo "======================================"
    echo "        Server Installation Script"
    echo "======================================"
    echo "1) Install on a new server"
    echo "2) Migrate from an old server, then install"
    echo
    read -r -p "Choose an option (1 or 2): " INSTALL_CHOICE
    case "$INSTALL_CHOICE" in
        1) BACKUP_MODE=0 ;;
        2)
            BACKUP_MODE=1
            read -r -p "Enter old server IP/hostname: " OLD_SERVER
            if [[ ! "$OLD_SERVER" =~ ^[A-Za-z0-9.-]+$ ]]; then
                echo "ERROR: Invalid server IP/hostname."
                exit 1
            fi
            ;;
        *) echo "ERROR: Invalid selection."; exit 1 ;;
    esac
}

transfer_from_old_server() {
    local stage db_dir cert_dir cert_pub key_pub
    stage="$(mktemp -d /tmp/vray-migration.XXXXXX)"
    trap 'rm -rf "$stage"' RETURN
    mkdir -p "$stage/certs" /root/x-ui/db

    echo
    echo "===== Transfer database and SSL files from old server ====="
    echo "Copying x-ui.db..."
    scp -o StrictHostKeyChecking=accept-new "root@${OLD_SERVER}:/root/x-ui/db/x-ui.db" "$stage/x-ui.db"
    test -s "$stage/x-ui.db" || { echo "ERROR: Database file is missing or empty."; return 1; }

    echo "Copying fullchain.pem..."
    scp -o StrictHostKeyChecking=accept-new "root@${OLD_SERVER}:/etc/letsencrypt/live/masterboot.net/fullchain.pem" "$stage/certs/fullchain.pem"
    echo "Copying privkey.pem..."
    scp -o StrictHostKeyChecking=accept-new "root@${OLD_SERVER}:/etc/letsencrypt/live/masterboot.net/privkey.pem" "$stage/certs/privkey.pem"

    test -s "$stage/certs/fullchain.pem" || { echo "ERROR: fullchain.pem is missing or empty."; return 1; }
    test -s "$stage/certs/privkey.pem" || { echo "ERROR: privkey.pem is missing or empty."; return 1; }

    echo "Validating transferred SSL certificate and private key..."
    openssl x509 -in "$stage/certs/fullchain.pem" -noout -checkend 0 >/dev/null
    openssl pkey -in "$stage/certs/privkey.pem" -noout >/dev/null
    cert_pub="$(openssl x509 -in "$stage/certs/fullchain.pem" -pubkey -noout | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
    key_pub="$(openssl pkey -in "$stage/certs/privkey.pem" -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
    [[ -n "$cert_pub" && "$cert_pub" == "$key_pub" ]] || {
        echo "ERROR: The SSL certificate and private key do not match."
        return 1
    }

    db_dir="/root/x-ui/db"
    cert_dir="/etc/letsencrypt/live/masterboot.net"
    mkdir -p "$db_dir" "$cert_dir"

    if [[ -e "$db_dir/x-ui.db" ]]; then
        cp -a "$db_dir/x-ui.db" "$db_dir/x-ui.db.bak.$(date +%Y%m%d%H%M%S)"
    fi
    install -o root -g root -m 600 "$stage/x-ui.db" "$db_dir/x-ui.db"
    install -o root -g root -m 644 "$stage/certs/fullchain.pem" "$cert_dir/fullchain.pem"
    install -o root -g root -m 600 "$stage/certs/privkey.pem" "$cert_dir/privkey.pem"

    echo "Database and SSL files transferred and validated successfully."
}

show_menu

echo
 echo "===== Update System ====="
apt update
DEBIAN_FRONTEND=noninteractive apt install -y certbot unzip curl ufw openssh-client openssl

if [[ "$BACKUP_MODE" -eq 1 ]]; then
    transfer_from_old_server
fi

echo
echo "===== Install and Configure SNMP ====="
apt-get install -y snmpd snmp
if [[ -f /etc/snmp/snmpd.conf ]]; then
    cp -a /etc/snmp/snmpd.conf "/etc/snmp/snmpd.conf.bak.$(date +%Y%m%d%H%M%S)"
fi
cat > /etc/snmp/snmpd.conf <<'SNMPEOF'
rocommunity fan@solar
syslocation "Your Location"
syscontact victor.mohsen@gmail.com
SNMPEOF
systemctl enable snmpd
systemctl restart snmpd
ufw allow 161/udp
ufw reload
echo "SNMP configured successfully."

echo
echo "===== Install Docker ====="
curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
bash /tmp/get-docker.sh
rm -f /tmp/get-docker.sh

echo
echo "===== Configure GRE Tunnel ====="
LOCAL_IP="$(ip -4 route get 8.8.8.8 | awk '{print $7; exit}')"
if [[ -z "$LOCAL_IP" ]]; then
    echo "ERROR: Could not detect local IPv4 address."
    exit 1
fi
echo "Detected Local IP: $LOCAL_IP"
read -r -p "Enter Iran Public IP (Remote): " REMOTE_IP
if [[ ! "$REMOTE_IP" =~ ^[A-Za-z0-9.-]+$ ]]; then
    echo "ERROR: Invalid remote IP/hostname."
    exit 1
fi

mkdir -p /etc/netplan
cat > /etc/netplan/gre.yaml <<EOF2
network:
  version: 2
  renderer: networkd
  ethernets:
    eth0:
      dhcp4: true
  tunnels:
    gre1:
      mode: gre
      local: $LOCAL_IP
      remote: $REMOTE_IP
      addresses:
        - 10.10.30.2/30
      mtu: 1400
EOF2

echo "Applying netplan..."
netplan generate
netplan apply

if [[ "$BACKUP_MODE" -eq 0 ]]; then
    echo
echo "===== SSL Certificate Selection ====="
    echo "1) Masterboot"
    read -r -p "Enter your choice (1): " DOMAIN_CHOICE
    case "$DOMAIN_CHOICE" in
        1)
            DOMAIN="Masterboot"
            SSL_URL="https://s3.ir-thr-at1.arvanstorage.ir/masterboot/letsencrypt.zip"
            ;;
        *)
            echo "WARNING: Invalid selection; skipping SSL certificate installation."
            DOMAIN=""
            SSL_URL=""
            ;;
    esac

    if [[ -n "$SSL_URL" ]]; then
        echo "Downloading SSL certificate archive..."
        SSL_FILE="/tmp/letsencrypt.zip"
        if curl -fL --connect-timeout 15 --max-time 60 "$SSL_URL" -o "$SSL_FILE"; then
            if unzip -t "$SSL_FILE" >/dev/null && unzip -Z1 "$SSL_FILE" | grep -q '^letsencrypt/'; then
                rm -rf /tmp/letsencrypt
                if unzip -o "$SSL_FILE" -d /tmp; then
                    if [[ -d /tmp/letsencrypt ]]; then
                        rm -rf /etc/letsencrypt
                        mv /tmp/letsencrypt /etc/letsencrypt
                        chmod -R 755 /etc/letsencrypt
                        echo "SSL certificates restored successfully."
                    else
                        echo "WARNING: letsencrypt directory not found in ZIP; skipping SSL installation."
                        DOMAIN=""
                    fi
                else
                    echo "WARNING: Failed to extract SSL certificate archive; skipping SSL installation."
                    DOMAIN=""
                fi
            else
                echo "WARNING: ZIP archive failed validation; skipping SSL installation."
                DOMAIN=""
            fi
        else
            echo "WARNING: Failed to download SSL certificate archive; skipping SSL installation."
            DOMAIN=""
        fi
        rm -f "$SSL_FILE"
    fi
else
    DOMAIN="Masterboot (transferred)"
    echo
    echo "Skipping SSL ZIP download because certificates were transferred from the old server."
fi

echo
echo "===== Install 3X-UI ====="
mkdir -p /root/x-ui/db
cd /root/x-ui
cat > docker-compose.yml <<'COMPOSEEOF'
version: '3.9'
services:
  xui:
    image: ghcr.io/mhsanaei/3x-ui:v2.8.8
    container_name: x-ui
    volumes:
      - /root/x-ui/db/:/etc/x-ui/
      - /etc/letsencrypt/:/etc/letsencrypt/
    restart: unless-stopped
    network_mode: host
COMPOSEEOF

echo "Starting 3X-UI..."
if command -v docker-compose >/dev/null 2>&1; then
    docker-compose up -d
else
    docker compose up -d
fi

echo
echo "======================================"
echo "Installation completed successfully!"
echo "======================================"
echo "GRE Local IP : $LOCAL_IP"
echo "GRE Remote IP: $REMOTE_IP"
echo "Tunnel IP    : 10.10.30.2/30"
echo "SSL Domain   : ${DOMAIN:-Not installed}"
echo "SNMP         : Configured"
echo "3X-UI        : Started"
echo "======================================"
echo
echo "Installation completed."
read -r -p "Reboot in 10 seconds? Type YES to confirm: " REBOOT_CONFIRM
if [[ "$REBOOT_CONFIRM" == "YES" ]]; then
    sleep 10
    reboot
else
    echo "Reboot skipped."
fi
