#!/bin/bash
set -eo pipefail

# Konfiguracja blokady
LOCK_FILE="/tmp/${SCRIPT_NAME}.lock"

# Blokada plikowa z timeout 0 (natychmiastowe wyjście jeśli zablokowane)
exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
    echo "Inna instancja skryptu już działa. Wyjście." >&2
    exit 1
fi

# Konfiguracja
SCRIPT_NAME=$(basename "$0" .sh)
LOG_FILE="${SCRIPT_NAME}.out"
TMP_LOGS_DIR=$(mktemp -d "/tmp/${SCRIPT_NAME}_tmp.XXXXXX")
CLEANUP_SAFE=false

# MOUNT: Nowe zmienne konfiguracyjne
MOUNT_FILESYSTEM=false             # Ustaw na true aby włączyć montowanie
MOUNT_SOURCE="/dev/your_log_device" # Źródło filesystemu (np. /dev/sdx1)
MOUNT_TYPE="ext4"                  # Typ filesystemu (ext4, xfs itp.)

# Konfiguracja FTP
FTP_HOST="ftp.example.com"
FTP_USER="twój_użytkownik"
FTP_PASS="twoje_hasło"
FTP_REMOTE_DIR="/remote/logs"
FTP_PARALLEL=5

# Konfiguracja katalogów
search_dir=""  # Ustaw ścieżkę do wyszukiwania plików (pozostaw puste aby użyć pełnego mirrora)
local_mirror_dir="/ścieżka/do/lokalnego/katalogu"

# MOUNT: Flaga śledząca montowanie
FILESYSTEM_MOUNTED=false

# Przekierowanie wyjść do logu
exec >> "${LOG_FILE}" 2>&1

# Nagłówek logu
echo "=============================================="
echo "Start skryptu: $(date '+%Y-%m-%d %H:%M:%S')"
echo "PID procesu: $$"
echo "Tymczasowy katalog: ${TMP_LOGS_DIR}"
echo "=============================================="

# Funkcja czyszcząca
cleanup() {
    echo "Czyszczenie zasobów..."
    
    # MOUNT: Odmontowywanie filesystemu jeśli został zamontowany przez skrypt
    if [ "$FILESYSTEM_MOUNTED" = true ]; then
        echo "Odmontowywanie filesystemu z ${search_dir}"
        if umount "${search_dir}"; then
            echo "Filesystem odmontowany pomyślnie"
        else
            echo "Błąd przy odmontowywaniu filesystemu!" >&2
        fi
    fi
    
    if [ "$CLEANUP_SAFE" = true ]; then
        rm -rf "${TMP_LOGS_DIR}"
        echo "Katalog tymczasowy usunięty: ${TMP_LOGS_DIR}"
    else
        echo "Katalog tymczasowy pozostawiony: ${TMP_LOGS_DIR}"
    fi
}

# MOUNT: Nowa funkcja montująca
mount_logsfilesystem() {
    if [ "$MOUNT_FILESYSTEM" != "true" ]; then
        return 0
    fi

    if [ -z "${search_dir}" ]; then
        echo "Błąd: search_dir musi być ustawiony gdy MOUNT_FILESYSTEM=true" >&2
        exit 1
    fi

    echo "Przygotowanie filesystemu w ${search_dir}"
    
    # Sprawdzenie czy katalog istnieje
    if [ ! -d "${search_dir}" ]; then
        echo "Tworzenie katalogu montowania: ${search_dir}"
        mkdir -p "${search_dir}" || {
            echo "Nie udało się utworzyć katalogu" >&2
            exit 1
        }
    fi

    # Sprawdzenie czy już zamontowany
    if mountpoint -q "${search_dir}"; then
        echo "Filesystem jest już zamontowany w ${search_dir}"
        return 0
    fi

    # Próba montowania z retry
    for attempt in {1..3}; do
        echo "Próba montowania #${attempt}"
        if mount -t "${MOUNT_TYPE}" "${MOUNT_SOURCE}" "${search_dir}"; then
            FILESYSTEM_MOUNTED=true
            echo "Filesystem zamontowany pomyślnie"
            return 0
        fi
        sleep 2
    done

    echo "Krytyczny błąd montowania filesystemu!" >&2
    exit 1
}

# Funkcja kompresji plików
compress_uncompressed_files() {
    local work_dir="$1"
    
    echo "Sprawdzanie i kompresowanie plików w: ${work_dir}"
    
    find "${work_dir}" -type f -not -name "*.gz" -print0 | while IFS= read -r -d $'\0' file; do
        file_type=$(file -b "$file")
        if ! echo "$file_type" | grep -q "gzip compressed"; then
            echo "Kompresowanie pliku: ${file}"
            gzip -9 "${file}"
        fi
    done
    
    echo "Kompresja zakończona"
}

# Funkcja do wyszukiwania plików
find_recent_files() {
    local search_dir="$1"
    local days_ago="$2"

    echo "Wyszukiwanie plików w: ${search_dir}"
    find "${search_dir}" -type f -mtime "${days_ago}"
}

# Funkcja wysyłająca na FTP
send_to_ftp() {
    local local_dir="$1"
    local remote_dir="$2"

    echo "Rozpoczęcie transferu FTP: ${local_dir} -> ${remote_dir}"

    lftp -u "${FTP_USER}","${FTP_PASS}" "${FTP_HOST}" <<EOF
        set ftp:ssl-force true
        set ftp:ssl-auth TLS
        set ssl:verify-certificate no
        mirror --parallel=${FTP_PARALLEL} -R "${local_dir}" "${remote_dir}"
        quit
EOF

    if [ $? -eq 0 ]; then
        echo "Transfer FTP zakończony sukcesem"
    else
        echo "Błąd podczas transferu FTP!" >&2
        return 1
    fi
}

# Rejestracja trap dla sygnałów
trap cleanup EXIT TERM INT

# Główna logika skryptu
main() {
    # MOUNT: Montowanie filesystemu na początku
    mount_logsfilesystem

    if [ -n "${search_dir}" ]; then
        # Tryb wyszukiwania i kopiowania
        echo "Wyszukiwanie plików w katalogu: ${search_dir}"

        local RECENT_FILES
        RECENT_FILES=$(find_recent_files "${search_dir}" "-1")

        if [ -z "${RECENT_FILES}" ]; then
            echo "Brak plików zmodyfikowanych w ciągu ostatnich 24 godzin."
            exit 0
        fi

        echo "Znalezione pliki:"
        echo "${RECENT_FILES}"

        echo "Kopiowanie plików do: ${TMP_LOGS_DIR}"
        cp -v --preserve=all ${RECENT_FILES} "${TMP_LOGS_DIR}"
        
        compress_uncompressed_files "${TMP_LOGS_DIR}"
        
        send_to_ftp "${TMP_LOGS_DIR}" "${FTP_REMOTE_DIR}"
    else
        # Tryb pełnego mirrora
        echo "Wykonywanie pełnego mirrora katalogu: ${local_mirror_dir}"
        send_to_ftp "${local_mirror_dir}" "${FTP_REMOTE_DIR}"
    fi

    CLEANUP_SAFE=true

    echo "=============================================="
    echo "Zakończenie skryptu: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "=============================================="
}

# Wywołanie głównej funkcji
main
