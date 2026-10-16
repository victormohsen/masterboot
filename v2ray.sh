#!/usr/bin/env bash
set -Eeuo pipefail

# Run as root; this script changes networking, installs packages and reboots.
if [[ ${EUID} -ne 0 ]]; then
    echo "ERROR: Run this script as root (for example: sudo bash vray.sh)." >&2
    exit 1
fi

valid_ipv4() {
    local ip=$1 part
    local -a octets
    [[ $ip =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    IFS='.' read -r -a octets <<< "$ip"
    ((${#octets[@]} == 4)) || return 1
    for part in "${octets[@]}"; do
        [[ $part =~ ^[0-9]{1,3}$ ]] || return 1
        ((10#$part <= 255)) || return 1
    done
}

backup_and_transfer_database() {
    local old_ip tmp_file timestamp
    echo ""
    echo "===== Transfer Database from Old Server ====="
    read -r -p "Enter old server IPv4 address: " old_ip
    if ! valid_ipv4 "$old_ip"; then
        echo "ERROR: Invalid IPv4 address: $old_ip" >&2
        exit 1
    fi

    command -v scp >/dev/null 2>&1 || {
        echo "ERROR: scp is not installed. Install the OpenSSH client first." >&2
        exit 1
    }

    mkdir -p /root/x-ui/db
    tmp_file=$(mktemp /root/x-ui/db/x-ui.db.incoming.XXXXXX)
    trap 'rm -f "${tmp_file:-}"' RETURN

    echo "Copying database from root@${old_ip}:/root/x-ui/db/x-ui.db ..."
    if ! scp -p -o StrictHostKeyChecking=ask \
        "root@${old_ip}:/root/x-ui/db/x-ui.db" "$tmp_file"; then
        echo "ERROR: Database transfer failed. Existing destination database was not changed." >&2
        exit 1
    fi

    if [[ ! -s $tmp_file ]]; then
        echo "ERROR: The transferred database is empty; refusing to install it." >&2
        exit 1
    fi

    timestamp=$(date +%Y%m%d-%H%M%S)
    if [[ -e /root/x-ui/db/x-ui.db ]]; then
        cp -a /root/x-ui/db/x-ui.db "/root/x-ui/db/x-ui.db.backup-${timestamp}"
        echo "Existing database backed up to /root/x-ui/db/x-ui.db.backup-${timestamp}"
    fi

    install -o root -g root -m 600 "$tmp_file" /root/x-ui/db/x-ui.db
    rm -f "$tmp_file"
    trap - RETURN
    echo "Database copied to /root/x-ui/db/x-ui.db."
    echo "NOTE: For a consistent SQLite copy, stop X-UI on the old server or use SQLite's online backup before running this transfer."
}

run_installation() {
    echo ""
    echo "===== Update System ====="
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y certbot unzip curl ufw openssh-client

    echo ""
    echo "===== Install and Configure SNMP ====="
    DEBIAN_FRONTEND=noninteractive apt-get install -y snmpd snmp

    if [[ -f /etc/snmp/snmpd.conf ]]; then
        cp -a /etc/snmp/snmpd.conf "/etc/snmp/snmpd.conf.bak.$(date +%Y%m%d-%H%M%S)"
    fi

    # WARNING: replace the example community with a unique secret and restrict SNMP
    # access to the monitoring host/firewall before using this on an internet-facing server.
    cat > /etc/snmp/snmpd.conf <<'SNMP_EOF'
rocommunity fan@solar
syslocation "Your Location"
syscontact victor.mohsen@gmail.com
SNMP_EOF
    chmod 600 /etc/snmp/snmpd.conf
    systemctl enable snmpd
    systemctl restart snmpd

    # Do not open SNMP to the entire Internet. Add a source-specific UFW rule for your
    # monitoring server instead, e.g. ufw allow from MONITOR_IP to any port 161 proto udp.
    echo "WARNING: SNMP UDP/161 has NOT been opened globally. Restrict it to your monitoring IP if needed."

    echo ""
    echo "===== Install Docker ====="
    curl --fail --show-error --silent --location --proto '=https' --tlsv1.2 \
        https://get.docker.com -o /tmp/get-docker.sh
    bash /tmp/get-docker.sh
    rm -f /tmp/get-docker.sh

    echo ""
    echo "===== Configure GRE Tunnel ====="
    local local_ip remote_ip
    local_ip=$(ip -4 route get 8.8.8.8 | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')
    if ! valid_ipv4 "$local_ip"; then
        echo "ERROR: Could not determine a valid local IPv4 address." >&2
        exit 1
    fi
    echo "Detected Local IP: $local_ip"
    read -r -p "Enter Iran Public IP (Remote): " remote_ip
    if ! valid_ipv4 "$remote_ip"; then
        echo "ERROR: Invalid remote IPv4 address: $remote_ip" >&2
        exit 1
    fi

    mkdir -p /etc/netplan
    if [[ -f /etc/netplan/gre.yaml ]]; then
        cp -a /etc/netplan/gre.yaml "/etc/netplan/gre.yaml.bak.$(date +%Y%m%d-%H%M%S)"
    fi
    cat > /etc/netplan/gre.yaml <<NETPLAN_EOF
network:
  version: 2
  renderer: networkd

  ethernets:
    eth0:
      dhcp4: true

  tunnels:
    gre1:
      mode: gre
      local: ${local_ip}
      remote: ${remote_ip}
      addresses:
        - 10.10.30.2/30
      mtu: 1400
NETPLAN_EOF
    chmod 600 /etc/netplan/gre.yaml

    echo "Applying netplan. This may interrupt SSH connectivity if the network configuration is incorrect."
    netplan generate
    netplan apply

    echo ""
    echo "===== SSL Certificate Selection ====="
    echo "1) Masterboot"
    read -r -p "Enter your choice (1, or anything else to skip): " domain_choice

    local domain="" ssl_url="" ssl_file="/tmp/letsencrypt.zip"
    case "$domain_choice" in
        1)
            domain="Masterboot"
            ssl_url="https://s3.ir-thr-at1.arvanstorage.ir/masterboot/letsencrypt.zip"
            ;;
        *)
            echo "Skipping SSL certificate installation."
            ;;
    esac

    if [[ -n $ssl_url ]]; then
        echo "Downloading SSL certificate archive..."
        if curl --fail --show-error --silent --location --proto '=https' --tlsv1.2 \
            --connect-timeout 15 --max-time 60 "$ssl_url" -o "$ssl_file"; then
            if unzip -tq "$ssl_file" >/dev/null && unzip -Z1 "$ssl_file" | grep -q '^letsencrypt/'; then
                # Keep the current certificate directory until archive validation passes.
                local extract_dir
                extract_dir=$(mktemp -d /tmp/letsencrypt-extract.XXXXXX)
                if unzip -oq "$ssl_file" -d "$extract_dir" && [[ -d "$extract_dir/letsencrypt" ]]; then
                    if [[ -d /etc/letsencrypt ]]; then
                        mv /etc/letsencrypt "/etc/letsencrypt.backup.$(date +%Y%m%d-%H%M%S)"
                    fi
                    mv "$extract_dir/letsencrypt" /etc/letsencrypt
                    chmod -R go-rwx /etc/letsencrypt
                    echo "SSL certificate archive extracted. Verify its authenticity before relying on these certificates."
                else
                    echo "WARNING: Could not extract the expected letsencrypt directory; keeping existing certificates."
                fi
                rm -rf "$extract_dir"
            else
                echo "WARNING: SSL archive validation failed; keeping existing certificates."
            fi
        else
            echo "WARNING: Failed to download SSL archive; keeping existing certificates."
        fi
        rm -f "$ssl_file"
    fi

    echo ""
    echo "===== Configure 3X-UI ====="
    mkdir -p /root/x-ui/db
    cd /root/x-ui
    cat > docker-compose.yml <<'COMPOSE_EOF'
services:
  xui:
    image: ghcr.io/mhsanaei/3x-ui:v2.8.8
    container_name: x-ui
    volumes:
      - /root/x-ui/db/:/etc/x-ui/
      - /etc/letsencrypt/:/etc/letsencrypt/
    restart: unless-stopped
    network_mode: host
COMPOSE_EOF
    chmod 600 /root/x-ui/docker-compose.yml

    echo "Starting 3X-UI..."
    if docker compose version >/dev/null 2>&1; then
        docker compose up -d
    elif command -v docker-compose >/dev/null 2>&1; then
        docker-compose up -d
    else
        echo "ERROR: Docker Compose is unavailable." >&2
        exit 1
    fi

    echo ""
    echo "======================================"
    echo "Installation/configuration completed."
    echo "======================================"
    echo "GRE Local IP : $local_ip"
    echo "GRE Remote IP: $remote_ip"
    echo "Tunnel IP    : 10.10.30.2/30"
    [[ -n $domain ]] && echo "SSL Domain   : $domain" || echo "SSL Domain   : Not installed"
    echo "SNMP         : Configured (UDP/161 not opened globally)"
    echo "3X-UI        : Started"
    echo "======================================"

    read -r -p "Reboot this server in 10 seconds? Type YES to confirm: " reboot_confirm
    if [[ $reboot_confirm == "YES" ]]; then
        echo "Rebooting in 10 seconds..."
        sleep 10
        reboot
    else
        echo "Reboot skipped. Reboot manually after verifying network and services."
    fi
}

# Choose operation before making any system changes.
echo "======================================"
echo "        Server Management Script"
echo "======================================"
echo "1) Create/configure a new X-UI server"
echo "2) Transfer old database, then continue server setup"
read -r -p "Enter your choice [1-2]: " choice

case "$choice" in
    1)
        run_installation
        ;;
    2)
        backup_and_transfer_database
        run_installation
        ;;
    *)
        echo "Invalid choice. No changes were made." >&2
        exit 1
        ;;
esac
