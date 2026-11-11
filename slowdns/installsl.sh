
#!/bin/bash
set -Eeuo pipefail

# ==========================================
# KONFIGURASI
# ==========================================
DOMAIN="rhyuunet.biz.id"
DOMAIN_PATH_FILE="/etc/xray/domain"
SLOWDNS_DIR="/etc/slowdns"
REPO="https://raw.githubusercontent.com/Rhyuu11/opok/main/slowdns"
API="https://api.cloudflare.com/client/v4"

# ==========================================
# VALIDASI
# ==========================================
if [[ $EUID -ne 0 ]]; then
    echo "Script harus dijalankan sebagai root."
    exit 1
fi

for CMD in curl jq openssl; do
    if ! command -v "$CMD" >/dev/null 2>&1; then
        apt-get update
        apt-get install -y "$CMD"
    fi
done

if [[ ! -s "$DOMAIN_PATH_FILE" ]]; then
    echo "File $DOMAIN_PATH_FILE tidak ditemukan."
    exit 1
fi

DOMAIN_PATH=$(tr -d '[:space:]' < "$DOMAIN_PATH_FILE")

if [[ -z "$DOMAIN_PATH" ]]; then
    echo "Domain VPS kosong."
    exit 1
fi

# Gunakan Cloudflare API Token, bukan Global API Key
if [[ -z "${CF_API_TOKEN:-}" ]]; then
    read -rsp "Masukkan Cloudflare API Token: " CF_API_TOKEN
    echo
fi

if [[ -z "$CF_API_TOKEN" ]]; then
    echo "API Token kosong."
    exit 1
fi

CF_HEADER=(
    -H "Authorization: Bearer ${CF_API_TOKEN}"
    -H "Content-Type: application/json"
)

# ==========================================
# FUNGSI VALIDASI CLOUDFLARE
# ==========================================
cf_check() {
    local RESPONSE="$1"

    if [[ "$(jq -r '.success // false' <<< "$RESPONSE")" != "true" ]]; then
        echo "Cloudflare API gagal:"
        jq -r '.errors[]?.message // "Kesalahan tidak diketahui"' <<< "$RESPONSE"
        exit 1
    fi
}

# ==========================================
# MEMBUAT DOMAIN NS CLOUDFLARE
# ==========================================
ns_domain_cloudflare() {
    echo "Mengatur DNS Cloudflare..."

    IP=$(curl -4fsS https://api.ipify.org)

    ZONE_RESPONSE=$(
        curl -fsS "${API}/zones?name=${DOMAIN}&status=active" \
        "${CF_HEADER[@]}"
    )

    cf_check "$ZONE_RESPONSE"

    ZONE=$(jq -r '.result[0].id // empty' <<< "$ZONE_RESPONSE")

    if [[ -z "$ZONE" ]]; then
        echo "Zone ${DOMAIN} tidak ditemukan."
        exit 1
    fi

    # Membuat subdomain acak
    SUB=$(openssl rand -hex 4)
    SUB_DOMAIN="${SUB}.${DOMAIN}"
    NS_DOMAIN="ns.${SUB_DOMAIN}"

    echo "IP VPS       : ${IP}"
    echo "Domain NS    : ${NS_DOMAIN}"
    echo "Target NS    : ${DOMAIN_PATH}"

    # Cari record NS yang sudah ada
    RECORD_RESPONSE=$(
        curl -fsS \
        "${API}/zones/${ZONE}/dns_records?type=NS&name=${NS_DOMAIN}" \
        "${CF_HEADER[@]}"
    )

    cf_check "$RECORD_RESPONSE"

    RECORD=$(jq -r '.result[0].id // empty' <<< "$RECORD_RESPONSE")

    # Data DNS
    DNS_DATA=$(
        jq -n \
        --arg name "$NS_DOMAIN" \
        --arg content "$DOMAIN_PATH" \
        '{
            type: "NS",
            name: $name,
            content: $content,
            ttl: 300
        }'
    )

    # Buat record jika belum ada
    if [[ -z "$RECORD" ]]; then
        RESULT=$(
            curl -fsS -X POST \
            "${API}/zones/${ZONE}/dns_records" \
            "${CF_HEADER[@]}" \
            --data "$DNS_DATA"
        )
    else
        # Perbarui record jika sudah ada
        RESULT=$(
            curl -fsS -X PUT \
            "${API}/zones/${ZONE}/dns_records/${RECORD}" \
            "${CF_HEADER[@]}" \
            --data "$DNS_DATA"
        )
    fi

    cf_check "$RESULT"

    # Simpan domain NS
    echo "$NS_DOMAIN" > /etc/xray/dns

    echo "DNS Cloudflare berhasil dibuat."
}

# ==========================================
# INSTALASI DNSTT
# ==========================================
setup_dnstt() {
    echo "Menginstal SlowDNS..."

    mkdir -p "$SLOWDNS_DIR"

    # Download binary langsung ke folder SlowDNS
    curl -fL --retry 3 \
        "${REPO}/dnstt-server" \
        -o "${SLOWDNS_DIR}/dnstt-server"

    curl -fL --retry 3 \
        "${REPO}/dnstt-client" \
        -o "${SLOWDNS_DIR}/dnstt-client"

    chmod 755 \
        "${SLOWDNS_DIR}/dnstt-server" \
        "${SLOWDNS_DIR}/dnstt-client"

    # Generate key jika belum tersedia
    if [[ ! -s "${SLOWDNS_DIR}/server.key" ||
          ! -s "${SLOWDNS_DIR}/server.pub" ]]; then

        "${SLOWDNS_DIR}/dnstt-server" -gen-key \
            -privkey-file "${SLOWDNS_DIR}/server.key" \
            -pubkey-file "${SLOWDNS_DIR}/server.pub"
    fi

    chmod 600 "${SLOWDNS_DIR}/server.key"
    chmod 644 "${SLOWDNS_DIR}/server.pub"

    # Download service
    curl -fL --retry 3 \
        "${REPO}/client" \
        -o /etc/systemd/system/client.service

    curl -fL --retry 3 \
        "${REPO}/server" \
        -o /etc/systemd/system/server.service

    # Ganti placeholder xxxx dengan domain NS
    for SERVICE in \
        /etc/systemd/system/client.service \
        /etc/systemd/system/server.service
    do
        if ! grep -q 'xxxx' "$SERVICE"; then
            echo "Placeholder xxxx tidak ditemukan di $SERVICE"
            exit 1
        fi

        sed -i "s|xxxx|${NS_DOMAIN}|g" "$SERVICE"
    done

    echo "Binary dan service berhasil dipasang."
}

# ==========================================
# MENJALANKAN SERVICE
# ==========================================
start_slowdns() {
    echo "Mengaktifkan SlowDNS..."

    systemctl daemon-reload

    systemctl enable client.service server.service

    systemctl restart client.service
    systemctl restart server.service

    sleep 2

    echo
    echo "===== STATUS SERVER ====="
    systemctl status server.service --no-pager -l || true

    echo
    echo "===== STATUS CLIENT ====="
    systemctl status client.service --no-pager -l || true

    echo
    echo "===== PORT DNSTT ====="
    ss -lunp | grep ':5300' || true
}

# ==========================================
# PROSES UTAMA
# ==========================================
ns_domain_cloudflare
setup_dnstt
start_slowdns

echo
echo "=================================="
echo "       SLOWDNS BERHASIL DIPASANG"
echo "=================================="
echo "Domain NS : $(cat /etc/xray/dns)"
echo "Public Key: ${SLOWDNS_DIR}/server.pub"
echo "=================================="

exit 0
