#!/bin/bash
# Moduł zbierania logów, montowania i kompresji (Bash 4.2 / RHEL 7)

mount_logs_filesystem() {
    if [ "${MOUNT_FILESYSTEM}" != "true" ]; then
        return 0
    fi

    local target="${MOUNT_TARGET:-$SEARCH_DIR}"
    if [ -z "${target}" ] || [ -z "${MOUNT_SOURCE}" ]; then
        log_error "MOUNT_FILESYSTEM=true wymaga ustawienia MOUNT_SOURCE oraz MOUNT_TARGET/SEARCH_DIR"
        return 1
    fi

    if [ ! -d "${target}" ]; then
        mkdir -p "${target}" || {
            log_error "Nie udało się utworzyć punktu montowania: ${target}"
            return 1
        }
    fi

    if mountpoint -q "${target}"; then
        log_info "Filesystem jest już zamontowany w ${target}"
        return 0
    fi

    local attempt
    for attempt in 1 2 3; do
        log_info "Próba montowania (${attempt}/3): ${MOUNT_SOURCE} -> ${target}"
        if mount -t "${MOUNT_TYPE:-ext4}" ${MOUNT_OPTIONS:+-o "$MOUNT_OPTIONS"} "${MOUNT_SOURCE}" "${target}"; then
            FILESYSTEM_MOUNTED="true"
            log_info "Filesystem zamontowany pomyślnie w ${target}"
            return 0
        fi
        sleep 2
    done

    log_error "Krytyczny błąd montowania filesystemu ${MOUNT_SOURCE} w ${target}"
    return 1
}

umount_logs_filesystem() {
    if [ "${FILESYSTEM_MOUNTED}" != "true" ]; then
        return 0
    fi
    local target="${MOUNT_TARGET:-$SEARCH_DIR}"
    if [ -n "${target}" ] && mountpoint -q "${target}"; then
        log_info "Odmontowywanie filesystemu z ${target}"
        if umount "${target}"; then
            FILESYSTEM_MOUNTED="false"
            log_info "Filesystem odmontowany pomyślnie"
        else
            log_warn "Zwykłe umount nie powiodło się, próba umount -l ${target}"
            if umount -l "${target}"; then
                FILESYSTEM_MOUNTED="false"
                log_warn "Filesystem odmontowany z opcją lazy (-l)"
            else
                log_error "Nie udało się odmontować ${target}"
                return 1
            fi
        fi
    fi
}

# Pobieranie logów ze zdalnych hostów jednym strumieniem (rsync lub tar over SSH)
collect_remote_hosts_logs() {
    local dest_dir="$1"
    if [ "${#HOSTS_LOGS_LIST[@]}" -eq 0 ]; then
        return 0
    fi

    local ssh_opts="-o BatchMode=yes -o ConnectTimeout=15"
    if [ -n "${REMOTE_SSH_KEY}" ]; then
        ssh_opts="${ssh_opts} -i ${REMOTE_SSH_KEY}"
    fi

    local entry host remote_dir host_safe target_subdir
    for entry in "${HOSTS_LOGS_LIST[@]}"; do
        IFS=":" read -r host remote_dir <<< "${entry}"
        if [ -z "${host}" ] || [ -z "${remote_dir}" ]; then
            log_warn "Pominięto nieprawidłowy wpis HOSTS_LOGS_LIST: ${entry}"
            continue
        fi

        host_safe="${host//@/_}"
        target_subdir="${dest_dir}/remote_${host_safe}"
        mkdir -p "${target_subdir}"

        log_info "Pobieranie plików z ${host}:${remote_dir} (mtime ${REMOTE_SSH_MTIME_DAYS:-+1})..."
        # Jeden tunel SSH + tar zamiast pętli scp per plik
        if ssh ${ssh_opts} "${host}" "cd '${remote_dir}' && find . -type f -mtime ${REMOTE_SSH_MTIME_DAYS:-+1} -print0 | tar --null -T - -cf -" 2>>"${LOG_FILE}" | tar -xf - -C "${target_subdir}" 2>>"${LOG_FILE}"; then
            log_info "Pobrano logi z hosta ${host}"
        else
            log_error "Błąd pobierania logów z hosta ${host}:${remote_dir}"
            return 1
        fi
    done
}

# Zbieranie lokalnych plików z zachowaniem struktury katalogów
collect_local_recent_files() {
    local src_dir="$1"
    local dest_dir="$2"
    local mtime_days="$3"

    if [ ! -d "${src_dir}" ]; then
        log_error "Katalog źródłowy nie istnieje: ${src_dir}"
        return 1
    fi

    local list_file="${WORK_DIR}/found_files.nul"
    local find_args=("${src_dir}" -type f -mtime "${mtime_days}")

    if [ "${SKIP_ACTIVE_WRITES}" = "true" ]; then
        find_args+=(-mmin +1)
    fi

    if [ -n "${SEARCH_EXCLUDE_PATHS}" ]; then
        local pat
        for pat in ${SEARCH_EXCLUDE_PATHS}; do
            find_args+=(-not -path "${pat}")
        done
    fi

    find_args+=(-print0)
    find "${find_args[@]}" > "${list_file}"

    if [ ! -s "${list_file}" ]; then
        log_info "Brak nowych plików spełniających kryteria w ${src_dir}"
        return 2
    fi

    local count
    count=$(tr -cd '\0' < "${list_file}" | wc -c)
    log_info "Znaleziono ${count} plików do przetworzenia w ${src_dir}"

    if command -v rsync >/dev/null 2>&1; then
        rsync -a --from0 --files-from="${list_file}" / "${dest_dir}/"
    else
        # Fallback bez rsync: tar z zachowaniem ścieżek względnych
        tar --null -T "${list_file}" -cf - | tar -xf - -C "${dest_dir}"
    fi
}

# Równoległa kompresja nieskompresowanych plików (gzip -6 zamiast sekwencyjnego gzip -9)
compress_uncompressed_files() {
    local work_dir="$1"
    local level="${GZIP_LEVEL:-6}"
    local jobs="${COMPRESS_PARALLEL:-4}"

    log_info "Kompresja nieskompresowanych plików w ${work_dir} (gzip -${level}, równoległość=${jobs})"

    find "${work_dir}" -type f -not -name "*.gz" -not -name "*.bz2" -not -name "*.xz" -not -name "*.zip" -print0 | \
        xargs -0 -r -P "${jobs}" -I {} bash -c '
            f="$1"
            lvl="$2"
            # Szybkie sprawdzenie magic bytes gzip (1f 8b) bez uruchamiania "file"
            magic=$(od -N2 -tx1 -An "$f" 2>/dev/null | tr -d " \n")
            if [ "$magic" != "1f8b" ]; then
                gzip -"$lvl" "$f"
            fi
        ' _ {} "${level}"
}

# Pakowanie całego katalogu roboczego w jedno archiwum tar.gz
pack_staging_archive() {
    local src_dir="$1"
    local out_dir="$2"
    local prefix="${ARCHIVE_PREFIX:-logs}"
    local ts
    ts=$(date '+%Y-%m-%d_%H-%M-%S')
    local archive_path="${out_dir}/${prefix}_${JOB_ID}_${ts}.tar.gz"

    if [ -z "$(ls -A "${src_dir}" 2>/dev/null)" ]; then
        log_error "Katalog roboczy jest pusty, brak plików do spakowania: ${src_dir}"
        return 1
    fi

    log_info "Tworzenie archiwum: ${archive_path}" >&2
    GZIP="-${GZIP_LEVEL:-6}" tar -czf "${archive_path}" -C "${src_dir}" .

    if [ "${GPG_ENCRYPT}" = "true" ] && [ -n "${GPG_RECIPIENT}" ]; then
        log_info "Szyfrowanie archiwum GPG dla odbiorcy: ${GPG_RECIPIENT}" >&2
        gpg --batch --yes --trust-model always -e -r "${GPG_RECIPIENT}" "${archive_path}"
        rm -f "${archive_path}"
        archive_path="${archive_path}.gpg"
    fi

    echo "${archive_path}"
}
