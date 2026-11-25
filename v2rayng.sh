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

# Installs a separate updater. It changes only local/remote inside gre1.
install_mikrotik_ssh_public_key() {
    local pubkey_pem open_ssh_key
    pubkey_pem="$(mktemp /tmp/greclient-rsa.XXXXXX.pub)"
    trap 'rm -f "$pubkey_pem"' RETURN

    cat > "$pubkey_pem" <<'GRE_PUBLIC_KEY_EOF'
-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA635/xLUnbLUXKwjCpcUx
fnFMmQXnzqVsgK+2TaJKVrz1PJ7o5gT7pnizqcMW26Eo5JZiqik7mhGe6IlX70s1
8CfJh59pgHUMl6Xs4VREQ0+dozwcCxSjlriARNeyMyT6e0lKN12+NhowOq6etkMi
syE4s2VD46ecQqvbiA/2gFzYwYpPpqfgx788iihidSejE7uNuDnS7GvUi7T0qq0r
8K7aAR8u/5YifefEljF1cpnSt9Yo8ziZgIzUctkGmg8s/6vUUeHN4Voyf+Z5pzHZ
UXa56AqJBgHtbAerV9C5ioyO+0D684blu5tkyPuocu8GRfiQGmi/kHHBY/RxPqWu
5QIDAQAB
-----END PUBLIC KEY-----
GRE_PUBLIC_KEY_EOF

    if ! command -v ssh-keygen >/dev/null 2>&1; then
        echo "ERROR: ssh-keygen is required to install the MikroTik public key."
        return 1
    fi

    open_ssh_key="$(ssh-keygen -i -m PKCS8 -f "$pubkey_pem")" || {
        echo "ERROR: Could not convert the uploaded PEM public key."
        return 1
    }
    [[ "$open_ssh_key" == ssh-rsa\ * ]] || {
        echo "ERROR: Converted key is not an OpenSSH RSA public key."
        return 1
    }

    install -d -o root -g root -m 700 /root/.ssh
    touch /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    chown root:root /root/.ssh/authorized_keys

    if ! grep -qF "$open_ssh_key" /root/.ssh/authorized_keys; then
        printf '%s %s\n' "$open_ssh_key" "greclient-mikrotik" >> /root/.ssh/authorized_keys
        echo "MikroTik SSH public key added to /root/.ssh/authorized_keys"
    else
        echo "MikroTik SSH public key already exists; no duplicate added."
    fi
}

install_gre_updater() {
    cat > /usr/local/sbin/update-gre-remote <<'UPDATER_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG="/etc/netplan/gre.yaml"
LOCK="/run/lock/update-gre-remote.lock"

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "ERROR: Run as root."
    exit 1
fi

if [[ $# -ne 1 ]]; then
    echo "Usage: update-gre-remote <MIKROTIK_PUBLIC_IPV4>"
    exit 2
fi

REMOTE_IP="$1"
python3 - "$REMOTE_IP" <<'PY'
import ipaddress, sys
try:
    ipaddress.IPv4Address(sys.argv[1])
except Exception:
    raise SystemExit("ERROR: remote must be a valid IPv4 address")
PY

LOCAL_IP="$(ip -4 route get 8.8.8.8 | awk '{print $7; exit}')"
if [[ -z "$LOCAL_IP" ]]; then
    echo "ERROR: Could not detect local IPv4 address."
    exit 1
fi

python3 - "$LOCAL_IP" <<'PY'
import ipaddress, sys
try:
    ipaddress.IPv4Address(sys.argv[1])
except Exception:
    raise SystemExit("ERROR: detected local address is not a valid IPv4 address")
PY

command -v netplan >/dev/null 2>&1 || { echo "ERROR: netplan not found."; exit 1; }
[[ -f "$CONFIG" ]] || { echo "ERROR: $CONFIG not found."; exit 1; }

mkdir -p /run/lock
exec 9>"$LOCK"
flock -n 9 || { echo "ERROR: Another GRE update is running."; exit 1; }

TMP="$(mktemp "${CONFIG}.tmp.XXXXXX")"
BACKUP="${CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
cleanup() { rm -f "$TMP"; }
trap cleanup EXIT

# Find the gre1 block and replace exactly one local and one remote key.
python3 - "$CONFIG" "$TMP" "$LOCAL_IP" "$REMOTE_IP" <<'PY'
import re, sys
src, dst, local_ip, remote_ip = sys.argv[1:]
with open(src, encoding="utf-8") as f:
    lines = f.readlines()

start = None
for i, line in enumerate(lines):
    if re.match(r'^\s{4}gre1:\s*(?:#.*)?(?:\r?\n)?$', line):
        start = i
        break
if start is None:
    raise SystemExit("ERROR: gre1 block not found in netplan file")

base_indent = len(lines[start]) - len(lines[start].lstrip())
end = len(lines)
for i in range(start + 1, len(lines)):
    if not lines[i].strip() or lines[i].lstrip().startswith("#"):
        continue
    indent = len(lines[i]) - len(lines[i].lstrip())
    if indent <= base_indent:
        end = i
        break

counts = {"local": 0, "remote": 0}
for i in range(start + 1, end):
    m = re.match(r'^(\s*)(local|remote):\s*.*?(\r?\n)?$', lines[i])
    if m:
        key = m.group(2)
        counts[key] += 1
        value = local_ip if key == "local" else remote_ip
        newline = "\n" if lines[i].endswith("\n") else ""
        lines[i] = f"{m.group(1)}{key}: {value}{newline}"

if counts != {"local": 1, "remote": 1}:
    raise SystemExit(f"ERROR: expected exactly one local and one remote in gre1; found {counts}")

with open(dst, "w", encoding="utf-8") as f:
    f.writelines(lines)
PY

if cmp -s "$CONFIG" "$TMP"; then
    echo "UNCHANGED: GRE local=$LOCAL_IP remote=$REMOTE_IP"
    exit 0
fi

cp -a "$CONFIG" "$BACKUP"
cat "$TMP" > "$CONFIG"
chmod --reference="$BACKUP" "$CONFIG"
chown --reference="$BACKUP" "$CONFIG"

if ! netplan generate; then
    echo "ERROR: netplan generate failed; restoring backup."
    cp -a "$BACKUP" "$CONFIG"
    netplan generate || true
    exit 1
fi

if ! netplan apply; then
    echo "ERROR: netplan apply failed; restoring backup."
    cp -a "$BACKUP" "$CONFIG"
    netplan generate || true
    netplan apply || true
    exit 1
fi

echo "UPDATED: GRE local=$LOCAL_IP remote=$REMOTE_IP"
echo "BACKUP: $BACKUP"
UPDATER_EOF

    chmod 750 /usr/local/sbin/update-gre-remote
    chown root:root /usr/local/sbin/update-gre-remote
    echo "Installed /usr/local/sbin/update-gre-remote"
}

show_menu

echo
echo "===== Update System ====="
apt update
DEBIAN_FRONTEND=noninteractive apt install -y certbot unzip curl ufw openssh-client openssl python3

# Authorize the matching MikroTik private key for SSH access as root.
install_mikrotik_ssh_public_key

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
# Keep the original server-side IP detection method from v2ray.sh.
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
if [[ -f /etc/netplan/gre.yaml ]]; then
    cp -a /etc/netplan/gre.yaml "/etc/netplan/gre.yaml.bak.$(date +%Y%m%d%H%M%S)"
fi
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

install_gre_updater
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
echo "GRE Updater  : /usr/local/sbin/update-gre-remote"
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
