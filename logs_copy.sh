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

# Konfiguracja transferu (FTP/SFTP)
TRANSFER_PROTOCOL="ftp" # Możliwe wartości: ftp, sftp
FTP_HOST="ftp.example.com"
SFTP_HOST="sftp.example.com" # Host dla SFTP
FTP_USER="twój_użytkownik"
FTP_PASS="twoje_hasło"
REMOTE_DIR="/remote/logs"
PARALLEL=5

# Konfiguracja katalogów i hostów
search_dir=""  # Ustaw ścieżkę do wyszukiwania plików (pozostaw puste aby użyć pełnego mirrora)
local_mirror_dir="/ścieżka/do/lokalnego/katalogu"
HOSTS_LOGS_LIST=("host1.example.com:/var/logs" "host2.example.com:/var/logs") # Lista hostów i katalogów

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
    
    if [ "$CLEANUP_SAFE" = true ]; then
        rm -rf "${TMP_LOGS_DIR}"
        echo "Katalog tymczasowy usunięty: ${TMP_LOGS_DIR}"
    else
        echo "Katalog tymczasowy pozostawiony: ${TMP_LOGS_DIR}"
    fi
}

# COPY_HOST_LOGS: Funkcja kopiująca logi z hostów zdalnych starsze niż 1 dzień
copy_host_logs() {
    local tmp_dir="$1"

    echo "Rozpoczęcie kopiowania logów z hostów zdalnych do katalogu tymczasowego: ${tmp_dir}"

    for host_entry in "${HOSTS_LOGS_LIST[@]}"; do
        IFS=":" read -r host remote_dir <<< "$host_entry"

        echo "Łączenie z hostem: ${host}, katalog: ${remote_dir}"

        # Wyszukiwanie plików starszych niż 1 dzień na hoście zdalnym
        files=$(ssh "${host}" "find ${remote_dir} -type f -mtime +1")
        
        if [ -z "$files" ]; then
            echo "Brak plików do skopiowania na hoście ${host}."
            continue
        fi

        # Kopiowanie każdego pliku do katalogu tymczasowego
        for file in $files; do
            echo "Kopiowanie pliku: ${file} z hosta ${host} do ${tmp_dir}"
            scp "${host}:${file}" "${tmp_dir}/" || {
                echo "Błąd podczas kopiowania pliku ${file} z hosta ${host}" >&2
                continue
            }
        done
    done

    echo "Kopiowanie logów z hostów zakończone."
}


# Funkcja przesyłająca pliki (obsługa FTP i SFTP)
send_to_server() {
    local local_dir="$1"
    local remote_dir="$2"

    echo "Rozpoczęcie transferu plików: ${local_dir} -> ${remote_dir} za pomocą ${TRANSFER_PROTOCOL}"

    if [ "${TRANSFER_PROTOCOL}" = "ftp" ]; then
        lftp -c "open -u ${FTP_USER},${FTP_PASS} ${FTP_HOST}; \
                 set ftp:ssl-force true; \
                 set ftp:ssl-auth TLS; \
                 set ssl:verify-certificate no; \
                 mirror --parallel=${PARALLEL} -R ${local_dir} ${remote_dir}; \
                 quit"
    elif [ "${TRANSFER_PROTOCOL}" = "sftp" ]; then
        lftp -c "open sftp://${FTP_USER}:${FTP_PASS}@${SFTP_HOST}; \
                 mirror --parallel=${PARALLEL} -R ${local_dir} ${remote_dir}; \
                 quit"
    else
        echo "Nieobsługiwany protokół transferu: ${TRANSFER_PROTOCOL}" >&2
        exit 1
    fi

    if [ $? -eq 0 ]; then
        echo "Transfer zakończony sukcesem za pomocą ${TRANSFER_PROTOCOL}"
    else
        echo "Błąd podczas transferu za pomocą ${TRANSFER_PROTOCOL}!" >&2
        return 1
    fi
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

# Rejestracja trap dla sygnałów
trap cleanup EXIT TERM INT

# Główna logika skryptu
main() {
    # COPY_HOST_LOGS: Kopiowanie logów z hostów zdalnych do katalogu tymczasowego.
    copy_host_logs "${TMP_LOGS_DIR}"

    if [ -n "${search_dir}" ]; then
        # Tryb wyszukiwania i kopiowania lokalnych plików.
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

        send_to_server "${TMP_LOGS_DIR}" "${REMOTE_DIR}"
    else
        # Tryb pełnego mirrora.
        echo "Wykonywanie pełnego mirrora katalogu: ${local_mirror_dir}"
        send_to_server "${local_mirror_dir}" "${REMOTE_DIR}"
    fi

    CLEANUP_SAFE=true

    echo "=============================================="
    echo "Zakończenie skryptu: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "=============================================="
}

# Wywołanie głównej funkcji.
main
