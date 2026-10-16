#!/bin/bash

set -e

show_menu() {
    echo "======================================"
    echo "        Server Management Script"
    echo "======================================"
    echo
    echo "1) Create a new X-UI server"
    echo "2) Transfer database from an old server"
    echo
    read -r -p "Enter your choice [1-2]: " OPERATION
    case "$OPERATION" in
        1) return 0 ;;
        2) transfer_database; exit $? ;;
        *) echo "Invalid choice. Please run the script again and select 1 or 2."; exit 1 ;;
    esac
}

transfer_database() {
    echo
    read -r -p "Enter the old server public IP address: " OLD_IP
    if [[ ! "$OLD_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo "ERROR: Please enter a valid IPv4 address."
        return 1
    fi
    local octet
    IFS='.' read -r -a octets <<< "$OLD_IP"
    for octet in "${octets[@]}"; do
        if (( octet < 0 || octet > 255 )); then
            echo "ERROR: Invalid IPv4 address: $OLD_IP"
            return 1
        fi
    done

    local DB_DIR="/root/x-ui/db"
    local DB_FILE="$DB_DIR/x-ui.db"
    echo
    echo "Source: root@${OLD_IP}:/root/x-ui/db/x-ui.db"
    echo "Destination: ${DB_FILE}"
    echo

    mkdir -p "$DB_DIR"
    if [[ -e "$DB_FILE" ]]; then
        echo "WARNING: A database already exists at $DB_FILE."
        read -r -p "Overwrite it? Type YES to continue: " CONFIRM
        if [[ "$CONFIRM" != "YES" ]]; then
            echo "Transfer cancelled; existing database was not changed."
            return 1
        fi
        cp -a "$DB_FILE" "${DB_FILE}.backup.$(date +%Y%m%d-%H%M%S)"
        echo "Existing database backed up."
    fi

    echo "Transferring database using SCP..."
    scp "root@${OLD_IP}:/root/x-ui/db/x-ui.db" "$DB_FILE"
    echo "Database transfer completed successfully."
    echo "Destination: $DB_FILE"
    echo "NOTE: This only copies the file. It does not stop/restart X-UI or reboot the server."
}

show_menu

# Option 1: original new-server installation flow starts here.

echo "======================================"
echo "        Server Installation Script"
echo "======================================"

echo ""
echo "===== Update System ====="

apt update
apt install -y certbot unzip curl ufw

echo ""
echo "===== Install and Configure SNMP ====="

apt-get install -y snmpd
apt-get install -y snmp

if [ -f /etc/snmp/snmpd.conf ]; then
    mv /etc/snmp/snmpd.conf /etc/snmp/snmpd.conf.bak
fi

cat > /etc/snmp/snmpd.conf << 'SNMPCONF'
rocommunity fan@solar
syslocation "Your Location"
syscontact victor.mohsen@gmail.com
SNMPCONF

systemctl enable snmpd
systemctl restart snmpd

ufw allow 161/udp
ufw reload

echo "SNMP configured successfully."

echo ""
echo "===== Install Docker ====="

curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
bash /tmp/get-docker.sh
rm -f /tmp/get-docker.sh

echo ""
echo "===== Configure GRE Tunnel ====="

LOCAL_IP=$(ip -4 route get 8.8.8.8 | awk '{print $7; exit}')

echo "Detected Local IP: $LOCAL_IP"

read -r -p "Enter Iran Public IP (Remote): " REMOTE_IP

mkdir -p /etc/netplan

cat > /etc/netplan/gre.yaml << NETPLAN
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
NETPLAN

echo "Applying netplan..."

netplan generate
netplan apply

echo ""
echo "===== SSL Certificate Selection ====="

echo ""
echo "Select the domain:"
echo "1) Masterboot"

read -r -p "Enter your choice (1): " DOMAIN_CHOICE

case "$DOMAIN_CHOICE" in
    1)
        DOMAIN="Masterboot"
        SSL_URL="https://s3.ir-thr-at1.arvanstorage.ir/masterboot/letsencrypt.zip"
        ;;
    *)
        echo "WARNING: Invalid selection."
        echo "Skipping SSL certificate installation..."
        DOMAIN=""
        SSL_URL=""
        ;;
esac

if [ -n "$SSL_URL" ]; then
    echo ""
    echo "Selected Domain: $DOMAIN"
    echo "Downloading SSL certificate..."

    SSL_FILE="/tmp/letsencrypt.zip"

    if curl -fL --connect-timeout 15 --max-time 60 "$SSL_URL" -o "$SSL_FILE"; then
        echo "SSL certificate download successful."
        rm -rf /etc/letsencrypt
        rm -rf /tmp/letsencrypt

        if unzip -o "$SSL_FILE" -d /tmp; then
            if [ -d "/tmp/letsencrypt" ]; then
                mv /tmp/letsencrypt /etc/
                chmod -R 755 /etc/letsencrypt
                echo ""
                echo "SSL certificates restored successfully."
                echo "Domain: $DOMAIN"
            else
                echo "WARNING: letsencrypt directory not found in ZIP."
                echo "Skipping SSL certificate installation..."
            fi
        else
            echo "WARNING: Failed to extract SSL certificate."
            echo "Skipping SSL certificate installation..."
        fi
    else
        echo "WARNING: Failed to download SSL certificate."
        echo "Skipping SSL certificate installation..."
    fi
    rm -f "$SSL_FILE"
fi

echo ""
echo "===== Install 3X-UI ====="

mkdir -p /root/x-ui
cd /root/x-ui

cat > docker-compose.yml << 'COMPOSE'
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
COMPOSE

echo "Starting 3X-UI..."

if command -v docker-compose >/dev/null 2>&1; then
    docker-compose up -d
else
    docker compose up -d
fi

echo ""
echo "======================================"
echo "Installation completed successfully!"
echo "======================================"

echo "GRE Local IP : $LOCAL_IP"
echo "GRE Remote IP: $REMOTE_IP"
echo "Tunnel IP    : 10.10.30.2/30"

if [ -n "$DOMAIN" ]; then
    echo "SSL Domain   : $DOMAIN"
else
    echo "SSL Domain   : Not installed"
fi

echo "SNMP         : Configured"
echo "3X-UI        : Started"

echo "======================================"
echo ""
echo "Installation completed."
echo "Rebooting in 10 seconds..."

sleep 10
reboot
