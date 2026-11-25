#!/bin/bash
set -euo pipefail

# Instalator log-transfer-v2 dla RHEL 7 (wymaga uprawnień root)
if [ "$(id -u)" -ne 0 ]; then
    echo "Uruchom instalator jako root." >&2
    exit 1
fi

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="/opt/log-transfer"
WEB_DIR="/var/www/log-dashboard"

echo "1. Tworzenie struktury katalogów w ${BASE_DIR}..."
mkdir -p "${BASE_DIR}/bin/lib" \
         "${BASE_DIR}/etc/jobs" \
         "${BASE_DIR}/etc/creds" \
         "${BASE_DIR}/var/spool" \
         "${BASE_DIR}/var/state/jobs" \
         "${BASE_DIR}/var/logs" \
         "${BASE_DIR}/backups"

cp -f "${SRC_DIR}/bin/log-transfer.sh" "${BASE_DIR}/bin/"
cp -f "${SRC_DIR}/bin/migrate-logs.py" "${BASE_DIR}/bin/"
cp -f "${SRC_DIR}/bin/lib/"* "${BASE_DIR}/bin/lib/"
cp -f "${SRC_DIR}/etc/template.conf" "${BASE_DIR}/etc/"

chmod 755 "${BASE_DIR}/bin/log-transfer.sh" "${BASE_DIR}/bin/migrate-logs.py"
chmod 750 "${BASE_DIR}/etc/creds"
chmod 1777 "${BASE_DIR}/var/spool"
chmod 755 "${BASE_DIR}/var/state" "${BASE_DIR}/var/state/jobs"

echo "2. Instalacja dashboardu w ${WEB_DIR}..."
mkdir -p "${WEB_DIR}"
cp -f "${SRC_DIR}/dashboard/"* "${WEB_DIR}/"
chmod 755 "${WEB_DIR}"
chmod 644 "${WEB_DIR}/"*

if [ -d /etc/httpd/conf.d ]; then
    cp -f "${SRC_DIR}/etc/httpd-log-dashboard.conf" /etc/httpd/conf.d/log-dashboard.conf
    echo "   Skopiowano /etc/httpd/conf.d/log-dashboard.conf (zweryfikuj 'Require ip' i zrestartuj httpd)."
fi

if [ -d /etc/logrotate.d ]; then
    cp -f "${SRC_DIR}/etc/logrotate-log-transfer" /etc/logrotate.d/log-transfer
fi

# SELinux na RHEL 7 (jeśli włączony)
if command -v chcon >/dev/null 2>&1 && command -v getenforce >/dev/null 2>&1; then
    if [ "$(getenforce)" != "Disabled" ]; then
        chcon -R -t httpd_sys_content_t "${WEB_DIR}" "${BASE_DIR}/var/state" || true
    fi
fi

echo "Instalacja zakończona. Następny krok: skan starych cronów:"
echo "  python ${BASE_DIR}/bin/migrate-logs.py --scan"
