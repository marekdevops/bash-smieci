#!/bin/bash
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

# shellcheck source=lib/common.sh
source "${LIB_DIR}/common.sh"
# shellcheck source=lib/collector.sh
source "${LIB_DIR}/collector.sh"
# shellcheck source=lib/transport.sh
source "${LIB_DIR}/transport.sh"

usage() {
    echo "Użycie: $0 --config <ścieżka_do_pliku.conf>" >&2
    exit 2
}

CONFIG_FILE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --config|-c)
            CONFIG_FILE="$2"
            shift 2
            ;;
        --help|-h)
            usage
            ;;
        *)
            echo "Nieznany parametr: $1" >&2
            usage
            ;;
    esac
done

if [ -z "${CONFIG_FILE}" ] || [ ! -f "${CONFIG_FILE}" ]; then
    echo "BŁĄD: Nie podano lub nie istnieje plik konfiguracyjny: '${CONFIG_FILE}'" >&2
    exit 2
fi

# Wczytanie konfiguracji zadania
# shellcheck disable=SC1090
source "${CONFIG_FILE}"

validate_job_id "${JOB_ID}" || exit 2

BASE_DIR="${BASE_DIR:-/opt/log-transfer}"
SPOOL_DIR="${BASE_DIR}/var/spool/${JOB_ID}"
STATE_DIR="${BASE_DIR}/var/state"
LOG_DIR="${BASE_DIR}/var/logs"
LOCK_FILE="${SPOOL_DIR}/${JOB_ID}.lock"
LOG_FILE="${LOG_DIR}/${JOB_ID}.log"

mkdir -p "${SPOOL_DIR}" "${STATE_DIR}/jobs" "${LOG_DIR}"
chmod 700 "${SPOOL_DIR}"

# Blokada flock przed włączeniem logowania lub nadpisaniem stanu
exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
    echo "Inna instancja zadania '${JOB_ID}' już działa. Wyjście." >&2
    exit 1
fi

exec >> "${LOG_FILE}" 2>&1

START_EPOCH=$(date +%s)
STARTED_AT=$(date '+%Y-%m-%dT%H:%M:%S%z')
WORK_DIR=$(mktemp -d "${SPOOL_DIR}/run.XXXXXX")
MANIFEST_FILE="${WORK_DIR}/manifest.txt"
: > "${MANIFEST_FILE}"

CLEANUP_SAFE="false"
FILESYSTEM_MOUNTED="false"
JOB_STATUS="ERROR"
JOB_EXIT_CODE=1
JOB_ERROR_MSG=""

write_final_report() {
    local finish_epoch finished_at duration py_bin
    finish_epoch=$(date +%s)
    finished_at=$(date '+%Y-%m-%dT%H:%M:%S%z')
    duration=$((finish_epoch - START_EPOCH))

    py_bin=$(detect_python)
    if [ -n "${py_bin}" ]; then
        "${py_bin}" "${LIB_DIR}/json_report.py" \
            --state-dir "${STATE_DIR}" \
            --job-id "${JOB_ID}" \
            --description "${JOB_DESCRIPTION:-}" \
            --owner "${OWNER_USER:-$(whoami)}" \
            --protocol "${TRANSFER_PROTOCOL}" \
            --remote-host "${FTP_HOST}" \
            --remote-dir "${REMOTE_DIR}" \
            --status "${JOB_STATUS}" \
            --exit-code "${JOB_EXIT_CODE}" \
            --started-at "${STARTED_AT}" \
            --finished-at "${finished_at}" \
            --finished-at-epoch "${finish_epoch}" \
            --duration-sec "${duration}" \
            --error-message "${JOB_ERROR_MSG}" \
            --manifest "${MANIFEST_FILE}" || log_error "Nie udało się zapisać raportu JSON"
    else
        log_error "Brak interpretera Python — raport JSON nie został wygenerowany"
    fi
}

cleanup() {
    local trap_rc=$?
    set +e
    if [ ${trap_rc} -ne 0 ] && [ "${JOB_STATUS}" != "OK" ]; then
        JOB_EXIT_CODE=${trap_rc}
        if [ -z "${JOB_ERROR_MSG}" ]; then
            JOB_ERROR_MSG="Skrypt zakończył się nieoczekiwanie z kodem ${trap_rc}"
        fi
    fi

    umount_logs_filesystem
    write_final_report

    if [ "${CLEANUP_SAFE}" = "true" ]; then
        rm -rf "${WORK_DIR}"
        log_info "Katalog roboczy usunięty: ${WORK_DIR}"
    else
        log_warn "Katalog roboczy zachowany do diagnostyki: ${WORK_DIR}"
    fi
    log_info "Koniec zadania '${JOB_ID}' | status=${JOB_STATUS} | rc=${JOB_EXIT_CODE}"
}

trap cleanup EXIT TERM INT

main() {
    log_info "=============================================="
    log_info "Start zadania: ${JOB_ID} (PID=$$, user=$(whoami))"
    log_info "Tryb=${TRANSFER_MODE:-search}, Protokół=${TRANSFER_PROTOCOL}, Cel=${FTP_HOST}:${REMOTE_DIR}"
    audit_log "START job=${JOB_ID} protocol=${TRANSFER_PROTOCOL} target=${FTP_HOST}:${REMOTE_DIR}"

    require_cmd lftp || { JOB_ERROR_MSG="Brak lftp"; exit 1; }
    require_cmd sha256sum || { JOB_ERROR_MSG="Brak sha256sum"; exit 1; }

    mount_logs_filesystem || {
        JOB_ERROR_MSG="Błąd montowania filesystemu ${MOUNT_SOURCE}"
        exit 1
    }

    local staging_dir="${WORK_DIR}/staging"
    mkdir -p "${staging_dir}"

    # 1. Zbieranie z hostów zdalnych (jeśli skonfigurowane)
    if [ "${#HOSTS_LOGS_LIST[@]}" -gt 0 ]; then
        collect_remote_hosts_logs "${staging_dir}" || {
            JOB_ERROR_MSG="Błąd zbierania logów ze zdalnych hostów"
            exit 1
        }
    fi

    # 2. Zbieranie lokalne lub tryb mirror
    if [ "${TRANSFER_MODE}" = "mirror" ]; then
        if [ -z "${LOCAL_MIRROR_DIR}" ] || [ ! -d "${LOCAL_MIRROR_DIR}" ]; then
            JOB_ERROR_MSG="Katalog LOCAL_MIRROR_DIR nie istnieje: ${LOCAL_MIRROR_DIR}"
            log_error "${JOB_ERROR_MSG}"
            exit 1
        fi
        transfer_directory_mirror "${LOCAL_MIRROR_DIR}" "${REMOTE_DIR}" "${MANIFEST_FILE}" || {
            JOB_ERROR_MSG="Błąd transferu mirror katalogu ${LOCAL_MIRROR_DIR}"
            exit 1
        }
    else
        local rc=0
        collect_local_recent_files "${SEARCH_DIR}" "${staging_dir}" "${SEARCH_MTIME_DAYS:--1}" || rc=$?
        if [ ${rc} -eq 1 ]; then
            JOB_ERROR_MSG="Błąd wyszukiwania plików w ${SEARCH_DIR}"
            exit 1
        elif [ ${rc} -eq 2 ] && [ -z "$(ls -A "${staging_dir}" 2>/dev/null)" ]; then
            log_info "Brak nowych plików do wysłania — kończę ze statusem OK."
            JOB_STATUS="OK"
            JOB_EXIT_CODE=0
            CLEANUP_SAFE="true"
            audit_log "FINISH job=${JOB_ID} status=OK files=0"
            return 0
        fi

        compress_uncompressed_files "${staging_dir}" || {
            JOB_ERROR_MSG="Błąd kompresji plików"
            exit 1
        }

        if [ "${PACK_ARCHIVE:-true}" = "true" ]; then
            local archive_out="${WORK_DIR}/archive"
            mkdir -p "${archive_out}"
            local archive_path
            archive_path=$(pack_staging_archive "${staging_dir}" "${archive_out}") || {
                JOB_ERROR_MSG="Błąd pakowania archiwum"
                exit 1
            }
            transfer_single_file "${archive_path}" "${REMOTE_DIR}" "${MANIFEST_FILE}" || {
                JOB_ERROR_MSG="Błąd wysyłki archiwum $(basename "${archive_path}")"
                exit 1
            }
        else
            transfer_directory_mirror "${staging_dir}" "${REMOTE_DIR}" "${MANIFEST_FILE}" || {
                JOB_ERROR_MSG="Błąd wysyłki plików z ${staging_dir}"
                exit 1
            }
        fi
    fi

    JOB_STATUS="OK"
    JOB_EXIT_CODE=0
    CLEANUP_SAFE="true"
    audit_log "FINISH job=${JOB_ID} status=OK"
}

main
