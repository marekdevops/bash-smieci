#!/bin/bash
#set -eo pipefail

# Konfiguracja blokady
# Konfiguracja blokady

SCRIPT_NAME=$(basename "$0" .sh)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LOCK_FILE="${SCRIPT_DIR}/tmp/${SCRIPT_NAME}.lock"

####ZANEZPIECZENIE
cleanup_old_lock() {
    if [ -f "${LOCK_FILE}" ]; then
        # Sprawdź czy plik jest starszy niż 1 dzień (1440 minut)
        if [ $(find "${LOCK_FILE}" -mmin +1440 2>/dev/null | wc -l) -gt 0 ]; then
            echo "Usuwanie starego pliku blokady (starszy niż 1 dzień): ${LOCK_FILE}"
            rm -f "${LOCK_FILE}"
        fi
    fi
}

# Sprawdź i usuń stary plik blokady przed utworzeniem nowego
cleanup_old_lock



# Blokada plikowa (natychmiastowe wyjście jeśli zablokowane)
if [ -f "$LOCK_FILE" ]; then
    echo "Inna instancja skryptu już działa. Wyjście." >&2
    exit 1
fi


# Konfiguracja
SCRIPT_NAME=$(basename "$0" .sh)
LOG_FILE="${SCRIPT_DIR}/out/${SCRIPT_NAME}.out"
TMP_LOGS_DIR=$(mktemp -d "${SCRIPT_DIR}/tmp/${SCRIPT_NAME}_tmp.XXXXXX")
CLEANUP_SAFE=false

# Konfiguracja FTP
FTP_HOST="ftp.chujumuju.pl"
FTP_USER="LOG"
FTP_PASS='******'
FTP_REMOTE_DIR="/ZDALNY/"
FTP_PARALLEL=5

# Konfiguracja katalogów
search_dir="/logi/"  # Ustaw ścieżkę do wyszukiwania plików (pozostaw puste aby użyć pełnego mirrora)
local_mirror_dir="/ścieżka/do/lokalnego/katalogu"

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
    # Zwolnienie blokady automatycznie przez flock
}

# Funkcja do wyszukiwania plików
find_recent_files() {
    local search_dir="$1"
    local days_ago="$2"

    #echo "Wyszukiwanie plików w: ${search_dir}"
    #echo "==========================================="
    #find "${search_dir}" -path "${search_dir}.snapshot" -prune -o -type f -mtime "${days_ago}"
    find "${search_dir}" -type f -mtime "${days_ago}"

}

# Funkcja wysyłająca na FTP
send_to_ftp() {
    local local_dir="$1"
    local remote_dir="$2"

    echo "Rozpoczęcie transferu FTP: ${local_dir} -> ${remote_dir}"
    lftp -c "set ftp:ssl-force true ; set ssl:verify-certificate no; set ftp:ssl-auth TLS; set ftp:ssl-protect-data yes; open -u ${FTP_USER},${FTP_PASS} ${FTP_HOST};  mput -O "${remote_dir}" "${local_dir}/*"; quit"


    if [ $? -eq 0 ]; then
        echo "Transfer FTP zakończony sukcesem"
    else
        echo "Błąd podczas transferu FTP!" >&2
        return 1
    fi
}

# Funkcja do pakowania plików
pack_logs() {
    local source_dir="$1"
    local timestamp=$(date '+%Y-%m-%d_%H-%M')
    local archive_name="logs_${timestamp}.tar.gz"
    local archive_path="${SCRIPT_DIR}/tmp/${archive_name}"
    
    echo "Pakowanie plików do archiwum: ${archive_name}"
    echo "Ścieżka archiwum: ${archive_path}"
    
    # Utworzenie archiwum tar.gz
    if tar -czf "${archive_path}" -C "${source_dir}" . ; then
        echo "Archiwum utworzone pomyślnie: ${archive_path}"
        echo "${archive_path}"  # Zwracanie ścieżki do archiwum
    else
        echo "Błąd podczas tworzenia archiwum!" >&2
        return 1
    fi
}

# Funkcja wysyłająca pojedynczy plik na FTP
send_file_to_ftp() {
    local local_file="$1"
    local remote_dir="$2"
    local filename=$(basename "${local_file}")

    echo "Rozpoczęcie transferu FTP pliku: ${filename} -> ${remote_dir}"
    lftp -c "set ftp:ssl-force true ; set ssl:verify-certificate no; set ftp:ssl-auth TLS; set ftp:ssl-protect-data yes; open -u ${FTP_USER},${FTP_PASS} ${FTP_HOST}; put -O \"${remote_dir}\" \"${local_file}\"; quit"

    if [ $? -eq 0 ]; then
        echo "Transfer FTP pliku ${filename} zakończony sukcesem"
    else
        echo "Błąd podczas transferu FTP pliku ${filename}!" >&2
        return 1
    fi
}

# Rejestracja trap dla sygnałów
trap cleanup EXIT TERM INT

# Główna logika skryptu
main() {
    touch $LOCK_FILE
    if [ -n "${search_dir}" ]; then
        # Tryb wyszukiwania i kopiowania
        echo "Wyszukiwanie plików w katalogu: ${search_dir}"
        echo "==========================================="

        local RECENT_FILES
        RECENT_FILES=$(find_recent_files "${search_dir}" "-14")
        if [ -z "${RECENT_FILES}" ]; then
            echo "Brak plików zmodyfikowanych w ciągu ostatnich 24 godzin."
            exit 0
        fi

        echo "Znalezione pliki:"
        echo "${RECENT_FILES}"

        echo "Kopiowanie plików do: ${TMP_LOGS_DIR}"
        cp -v --preserve=all ${RECENT_FILES} "${TMP_LOGS_DIR}"
        
        # Pakowanie plików
        echo "============================================"
        echo "Pakowanie plików..."
        local ARCHIVE_PATH
        ARCHIVE_PATH=$(pack_logs "${TMP_LOGS_DIR}")
        
        if [ $? -eq 0 ] && [ -f "${ARCHIVE_PATH}" ]; then
            echo "============================================"
            echo "Wysyłanie archiwum na FTP: ${FTP_REMOTE_DIR}"
            send_file_to_ftp "${ARCHIVE_PATH}" "${FTP_REMOTE_DIR}"
            
            # Usunięcie archiwum po udanej wysyłce
            if [ $? -eq 0 ]; then
                rm -f "${ARCHIVE_PATH}"
                echo "Archiwum usunięte po pomyślnej wysyłce: $(basename "${ARCHIVE_PATH}")"
            fi
        else
            echo "Błąd podczas pakowania - pomijanie wysyłki FTP"
        fi
    else
        # Tryb pełnego mirrora
        echo "Wykonywanie pełnego mirrora katalogu: ${local_mirror_dir}"
        #send_to_ftp "${local_mirror_dir}" "${FTP_REMOTE_DIR}"
    fi

    CLEANUP_SAFE=true
    rm $LOCK_FILE

    echo "=============================================="
    echo "Zakończenie skryptu: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "=============================================="
}

# Wywołanie głównej funkcji
main