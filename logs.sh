#!/bin/bash
set -eo pipefail

# Konfiguracja zmiennych
SCRIPT_NAME=$(basename "$0" .sh)
LOG_FILE="${SCRIPT_NAME}.out"
FIND_LOGS_DIR="/ścieżka/do/katalogu/źródłowego"  # Zmień na właściwą ścieżkę
TMP_LOGS_DIR=$(mktemp -d "/tmp/${SCRIPT_NAME}_tmp.XXXXXX")

# Przekierowanie wszystkich wyjść do pliku logu
exec > >(tee -a "${LOG_FILE}") 2>&1

# Nagłówek logu
echo "=============================================="
echo "Start skryptu: $(date '+%Y-%m-%d %H:%M:%S')"
echo "Tymczasowy katalog: ${TMP_LOGS_DIR}"
echo "=============================================="

# Funkcja czyszcząca
cleanup() {
    echo "Czyszczenie zasobów..."
    rm -rf "${TMP_LOGS_DIR}"
    echo "Katalog tymczasowy usunięty: ${TMP_LOGS_DIR}"
}

# Rejestracja trap dla sygnałów
trap cleanup EXIT TERM INT

# Wyszukiwanie i kopiowanie plików
echo "Rozpoczęcie wyszukiwania plików w: ${FIND_LOGS_DIR}"
RECENT_FILES=$(find "${FIND_LOGS_DIR}" -type f -mtime -1)

if [ -z "${RECENT_FILES}" ]; then
    echo "Brak plików zmodyfikowanych w ciągu ostatnich 24 godzin"
    exit 0
fi

echo "Znalezione pliki:"
echo "${RECENT_FILES}" | tee -a "${LOG_FILE}"

echo "Kopiowanie plików do: ${TMP_LOGS_DIR}"
cp -v --preserve=all ${RECENT_FILES} "${TMP_LOGS_DIR}" | tee -a "${LOG_FILE}"

# Podsumowanie
echo "=============================================="
echo "Liczba skopiowanych plików: $(ls "${TMP_LOGS_DIR}" | wc -l)"
echo "Zakończenie skryptu: $(date '+%Y-%m-%d %H:%M:%S')"
echo "=============================================="
