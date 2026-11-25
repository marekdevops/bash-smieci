#!/bin/bash
# nfs_mount_audit.sh
#
# Audyt montowań NFS:
#   - kto / co zamontował dany udział (fstab, systemd, autofs, zadanie z crontab,
#     korelacja czasu montowania z logiem crona, auditd),
#   - czy udział jest jeszcze używany (procesy: cwd/root/exe/otwarte pliki/mmap,
#     podmontowania, pliki loop, swap),
#   - czy jest powiązany z crontab (punkt montowania lub źródło występuje w linii
#     crona albo w skryptach/konfiguracjach wywoływanych z crona),
#   - czy można go bezpiecznie odmontować (i opcjonalnie odmontowuje).
#
# Zasada: zamontowane powinny być tylko udziały używane przez zadania z crontab.
#
# Kompatybilny z Bash 4.2 / RHEL 7 (działa też na nowszych systemach).
# Domyślnie tylko raportuje. Odmontowanie wymaga --umount i uprawnień roota.
#
# Kody wyjścia:
#   0 - brak problemów
#   1 - znaleziono montowania do posprzątania (spoza crona / pozostawione / stale)
#   2 - błąd wywołania

set -u
umask 077
PATH=/usr/sbin:/usr/bin:/sbin:/bin:$PATH
export LC_COLLATE=C LC_NUMERIC=C

PROG=$(basename "$0")

# ---------------------------------------------------------------- konfiguracja
FSTYPES="nfs,nfs4"                      # typy systemów plików objęte audytem
ALLOW_FILE="/etc/nfs-mount-audit.allow" # dodatkowe dozwolone punkty montowania
STAT_TIMEOUT=5                          # sekundy na sprawdzenie czy montowanie odpowiada
MIN_AGE=600                             # młodszych montowań (s) nie ruszamy - mogą być w trakcie użycia
CRON_WINDOW=900                         # okno (s) przed montowaniem, w którym szukamy startu zadania crona
SCAN_DEPTH=3                            # głębokość śledzenia skryptów wywoływanych z crona

DO_UMOUNT=false
INCLUDE_CRON_IDLE=false
INCLUDE_FSTAB=false
FORCE_STALE=false
VERBOSE=false

usage() {
    cat <<EOF
Użycie: $PROG [opcje]

Raportuje wszystkie montowania NFS i klasyfikuje je:
  BUSY         - używany przez procesy / ma podmontowania (nie ruszać)
  CRON_RUNNING - powiązany z crontab, zadanie właśnie działa (nie ruszać)
  CRON_IDLE    - powiązany z crontab, nikt go nie używa
                 (zadanie zamontowało i NIE odmontowało po sobie)
  NOT_IN_CRON  - nie występuje w crontab i nikt go nie używa -> do odmontowania
  FSTAB        - nie w crontab, ale zarządzany przez fstab/systemd
  AUTOFS       - zarządzany przez autofs (sam go wygasi)
  RECENT       - nieużywany, ale zamontowany niedawno (< --min-age)
  STALE        - serwer nie odpowiada (stale handle / zawieszony)

Opcje:
  -u, --umount            odmontuj bezpieczne pozycje (NOT_IN_CRON)
      --include-cron-idle odmontuj także CRON_IDLE (pozostawione przez zadania)
      --include-fstab     odmontuj także FSTAB (wróci po restarcie / mount -a!)
      --force-stale       odmontuj STALE przez umount -f, a gdy się nie uda umount -l
  -a, --allow FILE        plik z dodatkowymi dozwolonymi punktami montowania
                          lub źródłami (domyślnie: $ALLOW_FILE),
                          traktowane jak powiązane z crontab
      --min-age SEK       minimalny wiek montowania do odmontowania (domyślnie $MIN_AGE)
      --cron-window SEK   okno korelacji z logiem crona (domyślnie $CRON_WINDOW)
      --fstype LISTA      typy FS, domyślnie "$FSTYPES" (np. "nfs,nfs4,cifs")
  -v, --verbose           pokaż przeskanowane pliki crona i szczegóły
  -h, --help              pomoc

Aby dokładnie wiedzieć KTO zamontował (użytkownik, proces, polecenie),
włącz audyt wywołań mount/umount (RHEL 7):
  echo '-a always,exit -F arch=b64 -S mount,umount2 -k nfs_mount' >> /etc/audit/rules.d/nfs_mount.rules
  echo '-a always,exit -F arch=b32 -S mount,umount2 -k nfs_mount' >> /etc/audit/rules.d/nfs_mount.rules
  augenrules --load
Skrypt sam korzysta z tych zdarzeń (ausearch), jeśli są dostępne.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -u|--umount)          DO_UMOUNT=true ;;
        --include-cron-idle)  INCLUDE_CRON_IDLE=true ;;
        --include-fstab)      INCLUDE_FSTAB=true ;;
        --force-stale)        FORCE_STALE=true ;;
        -a|--allow)           ALLOW_FILE="${2:?brak argumentu dla $1}"; shift ;;
        --min-age)            MIN_AGE="${2:?brak argumentu dla $1}"; shift ;;
        --cron-window)        CRON_WINDOW="${2:?brak argumentu dla $1}"; shift ;;
        --fstype)             FSTYPES="${2:?brak argumentu dla $1}"; shift ;;
        -v|--verbose)         VERBOSE=true ;;
        -h|--help)            usage; exit 0 ;;
        *) echo "Nieznana opcja: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

for n in "$MIN_AGE" "$CRON_WINDOW"; do
    case "$n" in ''|*[!0-9]*) echo "Wartość musi być liczbą: '$n'" >&2; exit 2 ;; esac
done

IS_ROOT=false
[ "$(id -u)" -eq 0 ] && IS_ROOT=true
if $DO_UMOUNT && ! $IS_ROOT; then
    echo "Odmontowanie (--umount) wymaga uprawnień roota." >&2
    exit 2
fi

# katalog roboczy poza montowaniami - inaczej sam skrypt trzymałby montowanie
cd / || exit 2

WORK=$(mktemp -d "/tmp/${PROG%.sh}.XXXXXX") || exit 2
trap 'rm -rf "$WORK"' EXIT

NOW=$(date +%s)
UPTIME_S=$(awk '{printf "%d", $1}' /proc/uptime)
BOOT_TS=$((NOW - UPTIME_S))

# ---------------------------------------------------------------- pomocnicze
if [ -t 1 ]; then
    C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YEL=$'\e[33m'; C_BLU=$'\e[36m'; C_B=$'\e[1m'; C_0=$'\e[0m'
else
    C_RED=; C_GRN=; C_YEL=; C_BLU=; C_B=; C_0=
fi

log_syslog() {
    command -v logger >/dev/null 2>&1 && logger -t "$PROG" -p user.notice "$*" 2>/dev/null
    return 0
}

# Dekodowanie ścieżek z /proc/mounts (\040 spacja, \011 tab, \012 nl, \134 backslash)
unmangle() {
    local s="$1"
    s=${s//\\040/ }
    s=${s//\\011/$'\t'}
    s=${s//\\012/$'\n'}
    s=${s//\\134/\\}
    printf '%s' "$s"
}

human_age() {
    local s=$1 d h m
    d=$((s / 86400)); h=$((s % 86400 / 3600)); m=$((s % 3600 / 60))
    if [ $d -gt 0 ]; then printf '%dd %dh' $d $h
    elif [ $h -gt 0 ]; then printf '%dh %dm' $h $m
    else printf '%dm %ds' $m $((s % 60))
    fi
}

fmt_ts() { date -d "@$1" '+%Y-%m-%d %H:%M:%S'; }

re_escape() { printf '%s' "$1" | sed 's/[][\.*^$(){}?+|]/\\&/g'; }

is_fstype() {
    case ",$FSTYPES," in *",$1,"*) return 0 ;; esac
    return 1
}

# ---------------------------------------------------------------- montowania
declare -a MPS=()          # unikalne punkty montowania (kolejność z /proc/mounts)
declare -A M_SRC M_TYPE M_OPTS M_COUNT M_AGE
declare -a ALL_MPS=()      # wszystkie punkty montowania (do wykrywania podmontowań)
declare -a AUTOFS_MPS=()

while read -r src mp fstype opts _; do
    mp=$(unmangle "$mp")
    ALL_MPS+=("$mp")
    [ "$fstype" = "autofs" ] && AUTOFS_MPS+=("$mp")
    is_fstype "$fstype" || continue
    if [ -z "${M_COUNT[$mp]+x}" ]; then
        MPS+=("$mp")
        M_COUNT[$mp]=0
    fi
    M_COUNT[$mp]=$(( ${M_COUNT[$mp]} + 1 ))
    # przy montowaniach nałożonych ostatni wpis to ten widoczny (na wierzchu)
    M_SRC[$mp]=$(unmangle "$src")
    M_TYPE[$mp]=$fstype
    M_OPTS[$mp]=$opts
done < /proc/self/mounts

if [ ${#MPS[@]} -eq 0 ]; then
    echo "Brak zamontowanych systemów plików typu: $FSTYPES"
    exit 0
fi

printf '%s\n' "${MPS[@]}" > "$WORK/mps"

# Wiek montowań NFS z /proc/self/mountstats (pole "age:" w sekundach).
# Przy montowaniach nałożonych bierzemy najmłodsze (na wierzchu).
if [ -r /proc/self/mountstats ]; then
    while IFS=$'\t' read -r mp age; do
        mp=$(unmangle "$mp")
        [ -n "${M_COUNT[$mp]+x}" ] || continue
        if [ -z "${M_AGE[$mp]+x}" ] || [ "$age" -lt "${M_AGE[$mp]}" ]; then
            M_AGE[$mp]=$age
        fi
    done < <(awk '/^device /{mp=$5; next} $1=="age:"{print mp "\t" $2}' /proc/self/mountstats 2>/dev/null)
fi

# Czy ścieżka leży na którymś z audytowanych montowań (nie wolno jej dotykać - może wisieć)
on_audited_mount() {
    local p="$1" m
    for m in "${MPS[@]}"; do
        case "$p" in "$m"|"$m"/*) return 0 ;; esac
    done
    return 1
}

# ---------------------------------------------------------------- stan montowań (stale)
declare -A M_STALE
for mp in "${MPS[@]}"; do
    if timeout -s KILL "$STAT_TIMEOUT" stat -t -- "$mp" >/dev/null 2>&1; then
        M_STALE[$mp]=false
    else
        M_STALE[$mp]=true
    fi
done

# ---------------------------------------------------------------- procesy
# Mapa PID -> comm oraz PID -> crond-przodek (procesy uruchomione przez crond).
# Jedno przejście awk po /proc/*/stat: "pid (comm) stan ppid ..."
declare -A P_COMM P_CRON
while IFS=$'\t' read -r pid comm cpid; do
    P_COMM[$pid]=$comm
    [ -n "$cpid" ] && P_CRON[$pid]=$cpid
done < <(cat /proc/[0-9]*/stat 2>/dev/null | awk '
    {
        o = index($0, " ("); c = 0
        for (i = length($0); i > 0; i--) if (substr($0, i, 1) == ")") { c = i; break }
        if (!o || !c) next
        pid = substr($0, 1, o - 1)
        comm[pid] = substr($0, o + 2, c - o - 2)
        split(substr($0, c + 2), f, " "); ppid[pid] = f[2]
    }
    END {
        for (p in comm) {
            cr = ""; q = p
            for (n = 0; n < 64 && (q in ppid) && ppid[q] > 1; n++) {
                q = ppid[q]
                if (comm[q] == "crond" || comm[q] == "cron") { cr = q; break }
            }
            print p "\t" comm[p] "\t" cr
        }
    }')

# Zwraca PID procesu crond będącego przodkiem (lub nic)
cron_ancestor() {
    [ -n "${P_CRON[$1]:-}" ] || return 1
    echo "${P_CRON[$1]}"
}

proc_cmdline() {
    local c
    c=$(tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null)
    [ -z "$c" ] && c="[${P_COMM[$1]:-?}]"
    printf '%s' "${c% }"
}

proc_user() { stat -c %U "/proc/$1" 2>/dev/null || echo '?'; }

# Procesy działające jako zadania crona (potomkowie crond)
: > "$WORK/cron_running"
for pid in ${P_CRON[@]+"${!P_CRON[@]}"}; do   # bash 4.2 + set -u: pusta tablica
    printf '%s\t%s\n' "$pid" "$(proc_cmdline "$pid")" >> "$WORK/cron_running"
done

# Skan odwołań procesów do plików: cwd, root, exe, otwarte deskryptory, mmap.
# readlink na /proc nie dotyka serwera NFS, więc nie zawiesza się na stale mount.
scan_holders() {
    local out="$1"
    {
        find /proc/[0-9]*/cwd /proc/[0-9]*/root /proc/[0-9]*/exe /proc/[0-9]*/fd/ \
            -maxdepth 1 -type l -printf '%p\t%l\n' 2>/dev/null
        awk '{ line=$0; for (i=0; i<5; i++) sub(/^[^ ]+ +/, "", line);
               if (substr(line,1,1)=="/") print FILENAME "\t" line }' \
            /proc/[0-9]*/maps 2>/dev/null | sort -u
    } | awk -F'\t' -v mpsfile="$WORK/mps" -v self=$$ '
        BEGIN { while ((getline l < mpsfile) > 0) mps[++n] = l }
        {
            split($1, a, "/"); pid = a[3]
            if (pid == self) next
            kind = a[4]; if (kind == "fd") kind = "plik"
            path = $2; sub(/ \(deleted\)$/, "", path)
            best = ""
            for (i = 1; i <= n; i++) {
                m = mps[i]
                if ((path == m || index(path, m "/") == 1) && length(m) > length(best)) best = m
            }
            if (best != "") print best "\t" pid "\t" kind "\t" path
        }' | sort -u > "$out"
}

scan_holders "$WORK/holders"

# Podmontowania, pliki loop, swap
submounts_of() {
    local mp="$1" m
    for m in "${ALL_MPS[@]}"; do
        case "$m" in "$mp"/*) echo "$m" ;; esac
    done
}

kernel_users_of() {
    local mp="$1" f b
    for f in /sys/block/loop*/loop/backing_file; do
        [ -r "$f" ] || continue
        b=$(cat "$f" 2>/dev/null)
        case "$b" in "$mp"/*) echo "loop: ${f#/sys/block/} -> $b" | sed 's#/loop/backing_file##' ;; esac
    done
    if [ -r /proc/swaps ]; then
        awk 'NR>1{print $1}' /proc/swaps | while read -r b; do
            b=$(unmangle "$b")
            case "$b" in "$mp"/*) echo "swap: $b" ;; esac
        done
    fi
}

# ---------------------------------------------------------------- crontab
# Każde zadanie crona -> plik eN.txt (linia + treść skryptów/konfiguracji, które wywołuje)
#                     -> eN.desc (skąd pochodzi), eN.paths (ścieżki z samej linii)
CRON_N=0
declare -A SCANNED

extract_paths() {
    grep -oE '(^|[^A-Za-z0-9_.$}-])/[A-Za-z0-9_./@+:%,=-]+' 2>/dev/null \
        | sed -E 's#^[^/]##; s#[.,:;]+$##' | sort -u
}

skip_path() {
    case "$1" in
        /proc/*|/sys/*|/dev/*|/run/*|/tmp/*|/var/tmp/*) return 0 ;;
        /etc/shadow*|/etc/gshadow*|/etc/sudoers*|*/.ssh/*) return 0 ;;
        /bin/*|/sbin/*|/usr/bin/*|/usr/sbin/*|/lib/*|/lib64/*|/usr/lib/*|/usr/lib64/*|/usr/share/*) return 0 ;;
    esac
    on_audited_mount "$1" && return 0
    return 1
}

# scan_file PLIK ZADANIE GŁĘBOKOŚĆ - dopisuje treść pliku do zadania i śledzi ścieżki w nim
scan_file() {
    local f="$1" e="$2" depth="$3" p size
    skip_path "$f" && return
    [ -n "${SCANNED[$e:$f]+x}" ] && return
    SCANNED[$e:$f]=1
    [ -f "$f" ] && [ -r "$f" ] || return
    size=$(stat -c %s -- "$f" 2>/dev/null || echo 0)
    [ "$size" -le 2097152 ] || return
    grep -Iq . -- "$f" 2>/dev/null || return      # tylko pliki tekstowe
    echo "$f" >> "$WORK/e$e.files"
    { echo "### $f"; cat -- "$f"; } >> "$WORK/e$e.txt" 2>/dev/null
    [ "$depth" -lt "$SCAN_DEPTH" ] || return
    while read -r p; do
        [ -n "$p" ] && scan_file "$p" "$e" $((depth + 1))
    done < <(extract_paths < "$f")
}

# add_cron_entry ŹRÓDŁO UŻYTKOWNIK LINIA [PLIK_SKRYPTU]
add_cron_entry() {
    local src="$1" user="$2" line="$3" script="${4:-}" p e
    CRON_N=$((CRON_N + 1)); e=$CRON_N
    printf '%s (użytkownik: %s): %s\n' "$src" "$user" "$line" > "$WORK/e$e.desc"
    printf '%s\n' "$line" > "$WORK/e$e.txt"
    : > "$WORK/e$e.files"
    extract_paths <<< "$line" | while read -r p; do skip_path "$p" || echo "$p"; done > "$WORK/e$e.paths"
    [ -n "$script" ] && echo "$script" >> "$WORK/e$e.paths"
    if [ -n "$script" ]; then
        scan_file "$script" "$e" 1
    fi
    while read -r p; do
        [ -n "$p" ] && scan_file "$p" "$e" 1
    done < <(extract_paths <<< "$line")
}

# Plik crona: systemowy (z kolumną użytkownika) lub użytkownika
parse_crontab() {
    local file="$1" kind="$2" owner="$3" line user
    [ -r "$file" ] || return
    while IFS= read -r line || [ -n "$line" ]; do
        line=${line#"${line%%[![:space:]]*}"}
        case "$line" in ''|'#'*) continue ;; esac
        # przypisania zmiennych (PATH=..., MAILTO=...)
        [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*= ]] && continue
        if [ "$kind" = system ]; then
            if [[ "$line" == @* ]]; then user=$(awk '{print $2}' <<< "$line")
            else user=$(awk '{print $6}' <<< "$line"); fi
        else
            user=$owner
        fi
        add_cron_entry "$file" "$user" "$line"
    done < "$file"
}

parse_crontab /etc/crontab system root
for f in /etc/cron.d/*; do
    [ -f "$f" ] && parse_crontab "$f" system root
done
for d in /var/spool/cron /var/spool/cron/crontabs; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
        [ -f "$f" ] && parse_crontab "$f" user "$(basename "$f")"
    done
done
# skrypty uruchamiane przez run-parts / anacron
for d in /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
        [ -f "$f" ] && [ -x "$f" ] && add_cron_entry "$d" root "$f" "$f"
    done
done
if [ -r /etc/anacrontab ]; then
    while IFS= read -r line; do
        case "$line" in ''|'#'*) continue ;; esac
        [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] && continue
        add_cron_entry /etc/anacrontab root "$line"
    done < /etc/anacrontab
fi

CRON_UNREADABLE=false
if ! $IS_ROOT && [ -d /var/spool/cron ] && ! ls /var/spool/cron/ >/dev/null 2>&1; then
    CRON_UNREADABLE=true
fi

# Lista dozwolonych (plik --allow)
declare -a ALLOW=()
if [ -r "$ALLOW_FILE" ]; then
    while IFS= read -r line; do
        line=${line%%#*}
        line=$(echo "$line" | awk '{$1=$1; print}')
        [ -n "$line" ] && ALLOW+=("$line")
    done < "$ALLOW_FILE"
fi

# Zadania crona odwołujące się do montowania (po punkcie montowania lub źródle)
cron_entries_for() {
    local mp="$1" src="$2" re i
    [ "$CRON_N" -gt 0 ] || return
    re="$(re_escape "$mp")([^A-Za-z0-9_.-]|\$)"
    for i in $(seq 1 "$CRON_N"); do
        if grep -qE -- "$re" "$WORK/e$i.txt" 2>/dev/null \
           || { [[ "$src" == *:/* || "$src" == //* ]] && grep -qF -- "$src" "$WORK/e$i.txt" 2>/dev/null; }; then
            echo "$i"
        fi
    done
}

# Czy któreś z tych zadań właśnie działa (potomek crond wywołujący skrypt zadania)
cron_running_for() {
    local mp="$1"; shift
    local e p pid cmd
    [ -s "$WORK/cron_running" ] || return 1
    while IFS=$'\t' read -r pid cmd; do
        case "$cmd" in *"$mp"*) echo "$pid $cmd"; return 0 ;; esac
        for e in "$@"; do
            while read -r p; do
                [ -n "$p" ] || continue
                case "$cmd" in *"$p"*) echo "$pid $cmd"; return 0 ;; esac
            done < "$WORK/e$e.paths"
        done
    done < "$WORK/cron_running"
    return 1
}

# ---------------------------------------------------------------- kto zamontował
fstab_has() {
    local mp="$1"
    [ -r /etc/fstab ] || return 1
    awk -v mp="$mp" '
        $0 !~ /^[[:space:]]*#/ && NF >= 2 {
            p = $2; gsub(/\\040/, " ", p)
            if (p == mp) { found = 1; exit }
        }
        END { exit !found }' /etc/fstab
}

systemd_unit_for() {
    local mp="$1" unit info
    command -v systemctl >/dev/null 2>&1 || return 1
    command -v systemd-escape >/dev/null 2>&1 || return 1
    unit=$(systemd-escape -p --suffix=mount -- "$mp" 2>/dev/null) || return 1
    info=$(systemctl show -p FragmentPath -p SourcePath "$unit" 2>/dev/null) || return 1
    local frag src
    frag=$(sed -n 's/^FragmentPath=//p' <<< "$info")
    src=$(sed -n 's/^SourcePath=//p' <<< "$info")
    if [ -n "$frag" ] && [[ "$frag" != /run/systemd/generator* ]]; then
        echo "systemd: $unit ($frag)"; return 0
    fi
    if [ -n "$src" ]; then
        echo "systemd: $unit (wygenerowany z $src)"; return 0
    fi
    return 1
}

autofs_for() {
    local mp="$1" a parent
    parent=$(dirname -- "$mp")
    for a in "${AUTOFS_MPS[@]+"${AUTOFS_MPS[@]}"}"; do
        if [ "$a" = "$mp" ] || [ "$a" = "$parent" ]; then
            echo "autofs (mapa na $a)"; return 0
        fi
    done
    return 1
}

# Indeks uruchomień z logu crona: epoch \t użytkownik \t polecenie
build_cron_log_index() {
    local out="$WORK/cronlog" files=() f
    : > "$out"
    for f in /var/log/cron /var/log/cron-* /var/log/cron.log /var/log/syslog /var/log/syslog.1; do
        [ -r "$f" ] && [ -f "$f" ] && files+=("$f")
    done
    if [ ${#files[@]} -gt 0 ]; then
        local cur_year cur_mon
        cur_year=$(date +%Y); cur_mon=$(date +%m)
        { for f in "${files[@]}"; do
              case "$f" in *.gz) zcat -- "$f" ;; *) cat -- "$f" ;; esac
          done; } 2>/dev/null \
        | awk -v y="$cur_year" -v cm="$cur_mon" -v boot="$BOOT_TS" '
            BEGIN { split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", mn, " ")
                    for (i = 1; i <= 12; i++) mon[mn[i]] = i }
            /CROND?\[[0-9]+\]: \(.*\) CMD \(/ {
                if (!($1 in mon)) next
                split($3, t, ":")
                yy = (mon[$1] > cm + 0) ? y - 1 : y
                ts = mktime(yy " " mon[$1] " " $2 " " t[1] " " t[2] " " t[3])
                if (ts < boot - 60) next      # montowania nie są starsze niż start systemu
                l = $0
                sub(/.*CROND?\[[0-9]+\]: \(/, "", l)
                user = l; sub(/\).*/, "", user)
                cmd = l; sub(/^[^)]*\) CMD \(/, "", cmd); sub(/\)$/, "", cmd)
                print ts "\t" user "\t" cmd
            }' | sort -n -u > "$out"
    fi
    if [ ! -s "$out" ] && command -v journalctl >/dev/null 2>&1; then
        # bieżący rozruch (-b): montowania i tak nie są starsze
        journalctl -b -q --no-pager -o short-iso -t CROND -t CRON 2>/dev/null \
        | awk '/\) CMD \(/ {
                d = $1; gsub(/[-T:+]/, " ", d); split(d, t, " ")
                ts = mktime(t[1] " " t[2] " " t[3] " " t[4] " " t[5] " " t[6])
                l = $0
                sub(/.*\]: \(/, "", l)
                user = l; sub(/\).*/, "", user)
                cmd = l; sub(/^[^)]*\) CMD \(/, "", cmd); sub(/\)$/, "", cmd)
                print ts "\t" user "\t" cmd
            }' | sort -n -u > "$out"
    fi
}

build_cron_log_index

# Uruchomienia crona tuż przed chwilą montowania
cron_log_near() {
    local t="$1"
    [ -s "$WORK/cronlog" ] || return 1
    awk -F'\t' -v from=$((t - CRON_WINDOW)) -v to=$((t + 5)) \
        '$1 >= from && $1 <= to' "$WORK/cronlog" | tail -n 5
}

# Zdarzenia auditd dla montowania (wymaga reguły na syscall mount)
AUDIT_OK=false
if $IS_ROOT && command -v ausearch >/dev/null 2>&1; then
    if ausearch -sc mount -i > "$WORK/audit" 2>/dev/null && [ -s "$WORK/audit" ]; then
        AUDIT_OK=true
    fi
fi

audit_for() {
    local mp="$1"
    $AUDIT_OK || return 1
    awk -v mp="$mp" 'BEGIN { RS = "----" }
        index($0, "name=" mp " ") || index($0, "name=" mp "\n") || index($0, " " mp " ") || index($0, " " mp "\n") { last = $0 }
        END { if (last == "") exit 1; print last }' "$WORK/audit" \
    | awk '
        /^type=PROCTITLE/ { sub(/.*proctitle=/, ""); cmd = $0 }
        /^type=SYSCALL/ {
            if (match($0, /msg=audit\([^)]*\)/)) when = substr($0, RSTART + 10, RLENGTH - 11)
            for (i = 1; i <= NF; i++) {
                split($i, kv, "=")
                if (kv[1] ~ /^(auid|uid|pid|ppid|comm|exe|success)$/) v[kv[1]] = kv[2]
            }
        }
        END {
            printf "%s auid=%s uid=%s pid=%s ppid=%s exe=%s sukces=%s", when, v["auid"], v["uid"], v["pid"], v["ppid"], v["exe"], v["success"]
            if (cmd != "") printf " polecenie: %s", cmd
            printf "\n"
        }'
}

# ---------------------------------------------------------------- analiza
declare -A M_STATUS M_REASON
declare -a TO_UMOUNT=() TO_FORCE=()
PROBLEMS=0

# wyrównanie liczone w znakach (printf %-Ns liczy bajty, a etykiety mają polskie znaki)
say() {
    local pad=$((24 - ${#1}))
    [ $pad -lt 1 ] && pad=1
    printf '  %s%*s%s\n' "$1" "$pad" '' "$2"
}

echo "${C_B}Audyt montowań NFS na $(hostname) — $(fmt_ts "$NOW")${C_0}"
echo "Zadań crona przeanalizowanych: $CRON_N, montowań: ${#MPS[@]}"
$IS_ROOT || echo "${C_YEL}UWAGA: uruchomiono bez roota — lista procesów i crontabów użytkowników może być niepełna.${C_0}"
$CRON_UNREADABLE && echo "${C_YEL}UWAGA: brak dostępu do /var/spool/cron.${C_0}"
if ! $AUDIT_OK; then
    echo "${C_YEL}INFO: brak zdarzeń auditd dla mount — 'kto zamontował' ustalany pośrednio (patrz --help).${C_0}"
fi
echo

for mp in "${MPS[@]}"; do
    src=${M_SRC[$mp]}
    age=${M_AGE[$mp]:-}
    echo "${C_B}${C_BLU}== $mp${C_0}"
    say "Źródło:" "$src (${M_TYPE[$mp]})"
    say "Opcje:" "${M_OPTS[$mp]}"
    if [ "${M_COUNT[$mp]}" -gt 1 ]; then
        say "Nałożone montowania:" "${C_RED}${M_COUNT[$mp]}x — ktoś montuje bez sprawdzania 'mountpoint -q' i nie odmontowuje${C_0}"
    fi

    mount_ts=""
    if [ -n "$age" ]; then
        mount_ts=$((NOW - age))
        say "Zamontowany:" "$(fmt_ts "$mount_ts") ($(human_age "$age") temu)"
    else
        say "Zamontowany:" "nieznany czas (brak /proc/self/mountstats)"
    fi

    # --- kto zamontował
    manager=""
    if m=$(autofs_for "$mp"); then manager=$m
    elif m=$(systemd_unit_for "$mp"); then manager=$m
    elif fstab_has "$mp"; then manager="fstab (/etc/fstab)"
    fi
    say "Zarządca:" "${manager:-brak (ręcznie lub skrypt)}"

    if [ -n "$mount_ts" ] && [ $((mount_ts - BOOT_TS)) -lt 300 ]; then
        say "Kiedy:" "przy starcie systemu"
    fi

    mapfile -t entries < <(cron_entries_for "$mp" "$src")
    in_cron=false
    if [ ${#entries[@]} -gt 0 ]; then
        in_cron=true
        say "Powiązanie z crontab:" "TAK"
        for e in "${entries[@]}"; do
            echo "      - $(cat "$WORK/e$e.desc")"
            if $VERBOSE && [ -s "$WORK/e$e.files" ]; then
                sed 's/^/          plik: /' "$WORK/e$e.files"
            fi
        done
    else
        say "Powiązanie z crontab:" "NIE"
    fi
    allowed=false
    for a in "${ALLOW[@]+"${ALLOW[@]}"}"; do
        if [ "$a" = "$mp" ] || [ "$a" = "$src" ]; then allowed=true; fi
    done
    $allowed && say "Lista dozwolonych:" "TAK ($ALLOW_FILE)"

    if [ -n "$mount_ts" ] && near=$(cron_log_near "$mount_ts") && [ -n "$near" ]; then
        say "Cron przed montowaniem:" "(okno ${CRON_WINDOW}s, log crona)"
        while IFS=$'\t' read -r ts user cmd; do
            echo "      - $(fmt_ts "$ts") ($user) $cmd"
        done <<< "$near"
    fi

    if a=$(audit_for "$mp"); then
        say "auditd (ostatni mount):" "$a"
    fi

    # --- czy używany
    holders=$(awk -F'\t' -v mp="$mp" '$1 == mp' "$WORK/holders")
    subs=$(submounts_of "$mp")
    kusers=$(kernel_users_of "$mp")
    busy=false
    if [ -n "$holders" ]; then
        busy=true
        say "Używany przez:" ""
        cut -f2 <<< "$holders" | sort -un | while read -r pid; do
            kinds=$(awk -F'\t' -v p="$pid" '$2 == p {print $3}' <<< "$holders" | sort -u | paste -sd, -)
            sample=$(awk -F'\t' -v p="$pid" '$2 == p {print $4; exit}' <<< "$holders")
            via=""
            if c=$(cron_ancestor "$pid"); then via=" ${C_YEL}[zadanie crona, crond pid $c]${C_0}"; fi
            printf '      - pid %s, %s, %s [%s] %s%s\n' "$pid" "$(proc_user "$pid")" \
                "$(proc_cmdline "$pid" | cut -c1-120)" "$kinds" "$sample" "$via"
        done
    fi
    if [ -n "$subs" ]; then
        busy=true
        say "Podmontowania:" "$(paste -sd' ' - <<< "$subs")"
    fi
    if [ -n "$kusers" ]; then
        busy=true
        say "Użycie przez jądro:" "$(paste -sd';' - <<< "$kusers")"
    fi
    $busy || say "Używany przez:" "nikt (brak procesów, podmontowań, loop, swap)"

    running=""
    if $in_cron; then
        running=$(cron_running_for "$mp" "${entries[@]}") || running=""
    fi

    # --- klasyfikacja
    if [ "${M_STALE[$mp]}" = true ]; then
        status=STALE; reason="serwer nie odpowiada w ${STAT_TIMEOUT}s (stale/zawieszony)"
        if $busy; then reason="$reason; procesy wiszą na montowaniu — umount -l odłączy je od drzewa"; fi
        TO_FORCE+=("$mp")
    elif $busy; then
        status=BUSY; reason="w użyciu — nie odmontowywać"
    elif [ -n "$running" ]; then
        status=CRON_RUNNING; reason="zadanie crona właśnie działa: $running"
    elif [[ "$manager" == autofs* ]]; then
        status=AUTOFS; reason="autofs odmontuje po czasie bezczynności (timeout)"
    elif [ -n "$age" ] && [ "$age" -lt "$MIN_AGE" ]; then
        status=RECENT; reason="zamontowany $(human_age "$age") temu (< ${MIN_AGE}s) — może zaraz być użyty"
    elif $in_cron || $allowed; then
        status=CRON_IDLE
        reason="powiązany z crontab, ale nikt go nie używa — zadanie nie odmontowało po sobie (bezpieczne do odmontowania)"
        $INCLUDE_CRON_IDLE && TO_UMOUNT+=("$mp")
    elif [ -n "$manager" ]; then
        status=FSTAB; reason="spoza crontab, ale zarządzany przez: $manager (bezpieczny do odmontowania, wróci po restarcie)"
        $INCLUDE_FSTAB && TO_UMOUNT+=("$mp")
    else
        status=NOT_IN_CRON; reason="nie występuje w crontab i nikt go nie używa — bezpieczne do odmontowania"
        TO_UMOUNT+=("$mp")
    fi
    M_STATUS[$mp]=$status
    M_REASON[$mp]=$reason

    case "$status" in
        STALE|NOT_IN_CRON|CRON_IDLE|FSTAB) col=$C_RED; PROBLEMS=$((PROBLEMS + 1)) ;;
        BUSY|CRON_RUNNING|RECENT) col=$C_YEL ;;
        *) col=$C_GRN ;;
    esac
    [ "${M_COUNT[$mp]}" -gt 1 ] && [ "$status" != NOT_IN_CRON ] && PROBLEMS=$((PROBLEMS + 1))
    say "STATUS:" "${col}${C_B}${status}${C_0} — $reason"
    echo
done

# ---------------------------------------------------------------- podsumowanie
echo "${C_B}Podsumowanie${C_0}"
printf '  %-14s %-40s %s\n' STATUS "PUNKT MONTOWANIA" "ŹRÓDŁO"
for mp in "${MPS[@]}"; do
    printf '  %-14s %-40s %s\n' "${M_STATUS[$mp]}" "$mp" "${M_SRC[$mp]}"
done
echo

# ---------------------------------------------------------------- odmontowanie
do_umount() {
    local mp="$1" i
    for i in $(seq 1 "${M_COUNT[$mp]}"); do
        mountpoint -q -- "$mp" 2>/dev/null || break
        if ! timeout 60 umount -- "$mp"; then
            echo "  ${C_RED}BŁĄD: umount $mp nie powiódł się${C_0}"
            log_syslog "BŁĄD odmontowania $mp (${M_SRC[$mp]})"
            return 1
        fi
    done
    echo "  ${C_GRN}OK: odmontowano $mp${C_0}"
    log_syslog "odmontowano $mp (${M_SRC[$mp]}), status ${M_STATUS[$mp]}"
}

if $DO_UMOUNT; then
    if [ ${#TO_UMOUNT[@]} -eq 0 ] && { ! $FORCE_STALE || [ ${#TO_FORCE[@]} -eq 0 ]; }; then
        echo "Nic do odmontowania."
    fi
    if [ ${#TO_UMOUNT[@]} -gt 0 ]; then
        echo "${C_B}Odmontowywanie${C_0}"
        scan_holders "$WORK/holders2"   # ponowna weryfikacja tuż przed umount
        for mp in "${TO_UMOUNT[@]}"; do
            if awk -F'\t' -v mp="$mp" '$1 == mp {f=1} END {exit !f}' "$WORK/holders2" \
               || [ -n "$(submounts_of "$mp")" ]; then
                echo "  ${C_YEL}POMINIĘTO: $mp — w międzyczasie zaczął być używany${C_0}"
                continue
            fi
            do_umount "$mp"
        done
    fi
    if $FORCE_STALE && [ ${#TO_FORCE[@]} -gt 0 ]; then
        echo "${C_B}Wymuszone odmontowanie STALE${C_0}"
        for mp in "${TO_FORCE[@]}"; do
            if timeout 30 umount -f -- "$mp" 2>/dev/null; then
                echo "  ${C_GRN}OK: umount -f $mp${C_0}"
                log_syslog "umount -f $mp (stale)"
            elif timeout 30 umount -l -- "$mp"; then
                echo "  ${C_YEL}OK: umount -l $mp (lazy — procesy trzymające pliki nadal je mają)${C_0}"
                log_syslog "umount -l $mp (stale)"
            else
                echo "  ${C_RED}BŁĄD: nie udało się odmontować $mp${C_0}"
                log_syslog "BŁĄD odmontowania stale $mp"
            fi
        done
    fi
else
    if [ ${#TO_UMOUNT[@]} -gt 0 ]; then
        echo "Do odmontowania (uruchom z --umount):"
        printf '  umount %q\n' "${TO_UMOUNT[@]}"
    fi
    if [ ${#TO_FORCE[@]} -gt 0 ]; then
        echo "STALE (uruchom z --umount --force-stale):"
        for m in "${TO_FORCE[@]}"; do printf '  umount -f %q || umount -l %q\n' "$m" "$m"; done
    fi
    n_idle=0
    for mp in "${MPS[@]}"; do [ "${M_STATUS[$mp]}" = CRON_IDLE ] && n_idle=$((n_idle + 1)); done
    if [ $n_idle -gt 0 ] && ! $INCLUDE_CRON_IDLE; then
        echo "CRON_IDLE: $n_idle — zadania z crontab zostawiły montowania; odmontujesz je przez --umount --include-cron-idle,"
        echo "  ale przyczyną jest skrypt zadania (brak umount / trap EXIT) — popraw skrypt wskazany wyżej."
    fi
fi

[ $PROBLEMS -gt 0 ] && exit 1
exit 0
