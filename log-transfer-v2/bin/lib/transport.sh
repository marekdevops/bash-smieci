#!/bin/bash
# Moduł transportowy (FTP / FTPS / SFTP) z ochroną poświadczeń i manifestem plików

# Tworzy bezpieczny tymczasowy plik komend dla lftp (0600), żeby hasło nie było w ps aux
_build_lftp_auth_cmd_file() {
    local proto="$1"
    local cmd_file="$2"
    local body_cmds="$3"

    validate_credentials_file "${CREDENTIALS_FILE}" || return 1

    local ftp_pass
    ftp_pass=$(head -n 1 "${CREDENTIALS_FILE}" | tr -d '\r\n')
    if [ -z "${ftp_pass}" ]; then
        log_error "Plik poświadczeń jest pusty: ${CREDENTIALS_FILE}"
        return 1
    fi

    # Ucieczka znaków specjalnych w haśle dla lftp
    local escaped_pass
    escaped_pass=$(printf '%s' "${ftp_pass}" | sed 's/\\/\\\\/g; s/"/\\"/g')

    (
        umask 077
        {
            echo "set net:timeout ${FTP_TIMEOUT_SEC:-30}"
            echo "set net:max-retries ${FTP_MAX_RETRIES:-3}"
            echo "set net:reconnect-interval-base 5"
            echo "set ftp:passive-mode ${FTP_PASSIVE:-true}"

            if [ "${proto}" = "ftp" ]; then
                # Zwykły FTP z hasłem (bez TLS)
                echo "set ftp:ssl-allow no"
                echo "open -p ${FTP_PORT:-21} -u \"${FTP_USER}\",\"${escaped_pass}\" \"${FTP_HOST}\""
            elif [ "${proto}" = "ftps" ]; then
                echo "set ftp:ssl-force true"
                echo "set ftp:ssl-auth TLS"
                echo "set ftp:ssl-protect-data yes"
                if [ "${FTPS_VERIFY_CERT:-true}" = "true" ]; then
                    echo "set ssl:verify-certificate yes"
                    if [ -n "${FTPS_CA_FILE}" ]; then
                        echo "set ssl:ca-file \"${FTPS_CA_FILE}\""
                    fi
                else
                    echo "set ssl:verify-certificate no"
                fi
                echo "open -p ${FTP_PORT:-21} -u \"${FTP_USER}\",\"${escaped_pass}\" \"${FTP_HOST}\""
            elif [ "${proto}" = "sftp" ]; then
                local sftp_target="${SFTP_HOST:-$FTP_HOST}"
                if [ -n "${SFTP_KEY_FILE}" ]; then
                    echo "set sftp:connect-program \"ssh -a -x -i ${SFTP_KEY_FILE} -o UserKnownHostsFile=${SFTP_KNOWN_HOSTS} -o StrictHostKeyChecking=yes\""
                    echo "open sftp://${FTP_USER}@${sftp_target}:${SFTP_PORT:-22}"
                else
                    echo "open sftp://${FTP_USER}:\"${escaped_pass}\"@${sftp_target}:${SFTP_PORT:-22}"
                fi
            fi

            printf '%s\n' "${body_cmds}"
            echo "quit"
        } > "${cmd_file}"
        chmod 600 "${cmd_file}"
    )
}

# Wysyła pojedynczy plik (np. spakowane archiwum) i rejestruje wynik w manifeście
transfer_single_file() {
    local local_file="$1"
    local remote_dir="$2"
    local manifest_file="$3"

    local filename size_bytes sha256_hash
    filename=$(basename "${local_file}")
    size_bytes=$(stat -c '%s' "${local_file}")
    sha256_hash=$(sha256sum "${local_file}" | awk '{print $1}')

    local cmd_file="${WORK_DIR}/lftp_cmd_$$.txt"
    local body="mkdir -p \"${remote_dir}\" ; put -O \"${remote_dir}\" \"${local_file}\""

    _build_lftp_auth_cmd_file "${TRANSFER_PROTOCOL}" "${cmd_file}" "${body}" || {
        record_manifest_entry "${manifest_file}" "${filename}" "${size_bytes}" "${sha256_hash}" "failed"
        return 1
    }

    log_info "Rozpoczęcie transferu (${TRANSFER_PROTOCOL}): ${filename} (${size_bytes} B) -> ${FTP_HOST}:${remote_dir}"
    local rc=0
    lftp -f "${cmd_file}" || rc=$?
    rm -f "${cmd_file}"

    if [ ${rc} -eq 0 ]; then
        log_info "Transfer zakończony sukcesem: ${filename} (sha256=${sha256_hash})"
        record_manifest_entry "${manifest_file}" "${filename}" "${size_bytes}" "${sha256_hash}" "transferred"
        return 0
    else
        log_error "Błąd transferu (${TRANSFER_PROTOCOL}) pliku ${filename}, kod lftp=${rc}"
        record_manifest_entry "${manifest_file}" "${filename}" "${size_bytes}" "${sha256_hash}" "failed"
        return ${rc}
    fi
}

# Wysyła cały katalog (mirror -R) i rejestruje listę plików w manifeście
transfer_directory_mirror() {
    local local_dir="$1"
    local remote_dir="$2"
    local manifest_file="$3"

    local cmd_file="${WORK_DIR}/lftp_mirror_$$.txt"
    local body="mkdir -p \"${remote_dir}\" ; mirror --reverse --parallel=${FTP_PARALLEL:-4} --only-newer \"${local_dir}\" \"${remote_dir}\""

    _build_lftp_auth_cmd_file "${TRANSFER_PROTOCOL}" "${cmd_file}" "${body}" || return 1

    log_info "Rozpoczęcie transferu mirror (${TRANSFER_PROTOCOL}): ${local_dir} -> ${FTP_HOST}:${remote_dir}"
    local rc=0
    lftp -f "${cmd_file}" || rc=$?
    rm -f "${cmd_file}"

    local transfer_status="transferred"
    if [ ${rc} -ne 0 ]; then
        transfer_status="failed"
        log_error "Błąd transferu mirror (${TRANSFER_PROTOCOL}), kod lftp=${rc}"
    else
        log_info "Transfer mirror zakończony sukcesem"
    fi

    # Zbudowanie listy plików z katalogu lokalnego do manifestu JSON
    local f rel size_b sha
    while IFS= read -r -d '' f; do
        rel="${f#${local_dir}/}"
        size_b=$(stat -c '%s' "${f}")
        sha=$(sha256sum "${f}" | awk '{print $1}')
        record_manifest_entry "${manifest_file}" "${rel}" "${size_b}" "${sha}" "${transfer_status}"
    done < <(find "${local_dir}" -type f -print0)

    return ${rc}
}
