#!/bin/bash
# Wspólne funkcje dla log-transfer-v2 (kompatybilne z Bash 4.2 / RHEL 7)

# Bezpieczne ustawienie umask dla środowiska bankowego
umask 027

log_msg() {
    local level="$1"
    shift
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${ts}] [${level}] $*"
}

log_info() {
    log_msg "INFO" "$@"
}

log_warn() {
    log_msg "WARN" "$@" >&2
}

log_error() {
    log_msg "ERROR" "$@" >&2
    # Zapis błędów krytycznych do syslog/rsyslog dla audytu SIEM
    if command -v logger >/dev/null 2>&1; then
        logger -t "log-transfer[${JOB_ID:-unknown}]" -p user.err "$*" 2>/dev/null || true
    fi
}

audit_log() {
    if command -v logger >/dev/null 2>&1; then
        logger -t "log-transfer[${JOB_ID:-unknown}]" -p user.info "$*" 2>/dev/null || true
    fi
}

validate_job_id() {
    local job_id="$1"
    if [[ ! "${job_id}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo "BŁĄD: Nieprawidłowy JOB_ID: '${job_id}'. Dozwolone znaki: [a-zA-Z0-9_-]" >&2
        return 1
    fi
}

require_cmd() {
    local cmd="$1"
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        log_error "Brak wymaganego polecenia w systemie: ${cmd}"
        return 1
    fi
}

detect_python() {
    if command -v python3 >/dev/null 2>&1; then
        echo "python3"
    elif command -v python >/dev/null 2>&1; then
        echo "python"
    else
        echo ""
    fi
}

# Walidacja uprawnień pliku z poświadczeniami (musi być 0600 lub 0400)
validate_credentials_file() {
    local cred_file="$1"
    if [ -z "${cred_file}" ] || [ ! -f "${cred_file}" ]; then
        log_error "Brak pliku poświadczeń: ${cred_file}"
        return 1
    fi
    local perms
    perms=$(stat -c '%a' "${cred_file}" 2>/dev/null || echo "999")
    if [ "${perms}" != "600" ] && [ "${perms}" != "400" ]; then
        log_error "Niebezpieczne uprawnienia pliku poświadczeń (${perms}) dla ${cred_file}. Wymagane 600 lub 400."
        return 1
    fi
}

# Rejestracja pliku do raportu JSON (tablica manifestu: nazwa|rozmiar|sha256|status)
record_manifest_entry() {
    local manifest_file="$1"
    local rel_name="$2"
    local size_bytes="$3"
    local sha256_hash="$4"
    local status="$5"
    printf '%s|%s|%s|%s\n' "${rel_name}" "${size_bytes}" "${sha256_hash}" "${status}" >> "${manifest_file}"
}
