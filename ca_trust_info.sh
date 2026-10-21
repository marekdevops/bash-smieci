#!/usr/bin/env bash
# Szuka certyfikatów CA po nazwie we wszystkich miejscach mechanizmu ca-trust (RHEL 7/8/9)
# i pokazuje: w którym pliku leży każdy certyfikat, za co ten plik odpowiada, czy certyfikat
# trafia do wynikowego bundla (/etc/pki/tls/certs/ca-bundle.crt), czy jest zablokowany
# i czy wygasł. Sprawdza też pliki systemowe ca-trust (symlinki, blocklist/blacklist,
# kopie systemowego bundla w złych miejscach, nieaktualny extract, rpm -V).
# Na końcu wypisuje proponowane polecenia naprawcze.
#
# Skrypt NICZEGO nie zmienia w systemie - tylko czyta. Znalezione certyfikaty zapisuje
# jako PEM do katalogu -o (przydają się do blokowania certyfikatów systemowych).
#
# Użycie:
#   ./ca_trust_info.sh "CA bko"           # szukaj po nazwie (subject lub issuer, bez wielkości liter)
#   ./ca_trust_info.sh                    # tylko kontrola plików systemowych
#   ./ca_trust_info.sh -d 60 bko          # "wygasa wkrótce" = w ciągu 60 dni (domyślnie 30)
#   ./ca_trust_info.sh -p /etc/httpd -p /opt/app bko   # przeszukaj też inne katalogi/pliki
#   ./ca_trust_info.sh -o /root/bko bko   # katalog na PEM-y znalezionych certyfikatów

set -uo pipefail   # bez -e: grep/openssl/rpm zwracają != 0 w zwykłych sytuacjach

DAYS_WARNING=30
EXTRA_PATHS=()
OUT_DIR=""

SRC_ETC=/etc/pki/ca-trust/source
SRC_USR=/usr/share/pki/ca-trust-source
EXTRACTED=/etc/pki/ca-trust/extracted
TLS_BUNDLE=$EXTRACTED/pem/tls-ca-bundle.pem
SYSTEM_P11=$SRC_USR/ca-bundle.trust.p11-kit

if [ -t 1 ]; then
  RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; BLU=$'\e[34m'; BLD=$'\e[1m'; RST=$'\e[0m'
else
  RED=; GRN=; YEL=; BLU=; BLD=; RST=
fi

usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
ok()    { echo "  ${GRN}[OK]${RST} $*"; }
bad()   { echo "  ${RED}[!!]${RST} $*"; ISSUES=$((ISSUES + 1)); }
note()  { echo "  ${BLU}[--]${RST} $*"; }
hdr()   { echo; echo "${BLD}=== $* ===${RST}"; }
die()   { echo "BŁĄD: $*" >&2; exit 1; }

while getopts ":d:p:o:h" opt; do
  case "$opt" in
    d) [[ "$OPTARG" =~ ^[0-9]+$ ]] || die "-d: liczba dni musi być liczbą całkowitą"
       DAYS_WARNING=$OPTARG ;;
    p) EXTRA_PATHS+=("$OPTARG") ;;
    o) OUT_DIR=$OPTARG ;;
    h) usage 0 ;;
    *) usage 1 ;;
  esac
done
shift $((OPTIND - 1))
[ $# -le 1 ] || die "Podaj jedną nazwę (w cudzysłowie, jeśli ma spacje)"
NAME="${1:-}"

command -v openssl >/dev/null || die "Brak polecenia openssl"

TS=$(date +%Y%m%d_%H%M%S)
NOW=$(date +%s)
ISSUES=0
NEED_EXTRACT=false
FILE_ID=0
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

ACTIONS=()
declare -A ACTION_SEEN=() WHOLE_FILE=()   # WHOLE_FILE: pliki usuwane/podmieniane w całości
add_action() {
  [ -n "${ACTION_SEEN[$1]:-}" ] && return
  ACTION_SEEN[$1]=1
  ACTIONS+=("$1")
}

RHEL_MAJOR=$(sed -n 's/.*release \([0-9]\+\).*/\1/p' /etc/redhat-release 2>/dev/null)

# Katalog blokad: RHEL 9 - blocklist, RHEL 7/8 - blacklist (decyduje to, czego właścicielem jest pakiet)
BLOCK=""
for d in blocklist blacklist; do
  if rpm -qf "$SRC_ETC/$d" >/dev/null 2>&1; then BLOCK=$d; break; fi
done
if [ -z "$BLOCK" ]; then
  if [ "${RHEL_MAJOR:-0}" -ge 9 ]; then BLOCK=blocklist; else BLOCK=blacklist; fi
fi
OTHER_BLOCK=$([ "$BLOCK" = blocklist ] && echo blacklist || echo blocklist)

# ---------------------------------------------------------------------------
# 1. Pliki systemowe: co jest czym i czy jest w porządku
# ---------------------------------------------------------------------------
describe() { # ścieżka opis
  local p=$1 st
  if [ -L "$p" ]; then
    st="-> $(readlink "$p")"
  elif [ -d "$p" ]; then
    st="katalog, plików: $(find -L "$p" -maxdepth 1 -type f 2>/dev/null | wc -l)"
  elif [ -f "$p" ]; then
    st="certyfikatów: $(grep -cE -- '-----BEGIN (TRUSTED )?CERTIFICATE-----' "$p" 2>/dev/null)"
    [[ "$st" == *": 0" ]] && st="$(du -h "$p" | cut -f1)"
  else
    st="BRAK"
  fi
  printf "  %-55s [%s]\n        %s\n" "$p" "$st" "$2"
}

check_link() { # link oczekiwany_cel
  local l=$1 t=$2
  if [ -L "$l" ]; then
    if [ "$(readlink -f "$l")" = "$(readlink -f "$t")" ]; then
      ok "$l -> $(readlink "$l")"
    else
      bad "$l wskazuje na $(readlink "$l"), a powinien na $t"
      add_action "ln -sfn '$t' '$l'"
    fi
  elif [ -e "$l" ]; then
    bad "$l to ZWYKŁY PLIK/KATALOG, nie symlink - update-ca-trust go nie aktualizuje!"
    add_action "mv -v '$l' '/root/$(basename "$l").bak_$TS' && ln -s '$t' '$l'"
    LEGACY_PATHS+=("$l")
    WHOLE_FILE[$l]=1
  else
    note "$l nie istnieje"
  fi
}

hdr "1. Pliki systemowe ca-trust"
echo "  System:  $(cat /etc/redhat-release 2>/dev/null || echo nieznany)"
echo "  Pakiety: $(rpm -q ca-certificates p11-kit-trust 2>/dev/null | tr '\n' ' ')"
echo "  Katalog blokad dla tej wersji: $BLOCK"
[ "$(id -u)" -eq 0 ] || note "Uruchomiono bez roota - część plików może być nieczytelna"

echo
echo "  ${BLD}WEJŚCIE (źródła, z których update-ca-trust buduje bundle):${RST}"
describe "$SYSTEM_P11"        "RPM ca-certificates: CA Mozilli + wpisy distrust. NIE edytować i NIE usuwać."
describe "$SRC_USR/anchors"   "RPM innych pakietów: dodatkowe zaufane CA (niski priorytet)"
describe "$SRC_USR/$BLOCK"    "RPM innych pakietów: blokady"
describe "$SRC_ETC/anchors"   "ADMIN: Twoje zaufane CA (PEM/DER) - tu dodajesz i usuwasz własne"
describe "$SRC_ETC/$BLOCK"    "ADMIN: blokady (distrust) - wygrywają z anchors i z RPM, działają po certyfikacie, nie po nazwie"
describe "$SRC_ETC"           "ADMIN: pliki *.p11-kit z 'trust anchor --store' i certyfikaty BEGIN TRUSTED CERTIFICATE"
echo
echo "  ${BLD}WYJŚCIE (generuje update-ca-trust extract - nie edytować ręcznie):${RST}"
describe "$TLS_BUNDLE"                           "bundle TLS (PEM) - czytają go curl, dnf, python, openssl"
describe "$EXTRACTED/openssl/ca-bundle.trust.crt" "bundle OpenSSL z atrybutami zaufania (TRUSTED CERTIFICATE)"
describe "$EXTRACTED/pem/email-ca-bundle.pem"    "bundle S/MIME (poczta)"
describe "$EXTRACTED/pem/objsign-ca-bundle.pem"  "bundle do podpisywania kodu"
describe "$EXTRACTED/java/cacerts"               "keystore Java"
echo
echo "  ${BLD}ŚCIEŻKI ZGODNOŚCI (symlinki do WYJŚCIA):${RST}"
LEGACY_PATHS=()
check_link /etc/pki/tls/certs/ca-bundle.crt       "$TLS_BUNDLE"
check_link /etc/pki/tls/certs/ca-bundle.trust.crt "$EXTRACTED/openssl/ca-bundle.trust.crt"
check_link /etc/pki/tls/cert.pem                  "$TLS_BUNDLE"
check_link /etc/ssl/certs                         /etc/pki/tls/certs
[ -d /etc/pki/java ] && check_link /etc/pki/java/cacerts "$EXTRACTED/java/cacerts"

echo
echo "  ${BLD}KONTROLE:${RST}"
if [ -f "$SYSTEM_P11" ]; then
  ok "Systemowy bundle Mozilli na miejscu"
else
  bad "Brak $SYSTEM_P11 - brak wszystkich publicznych CA!"
  add_action "dnf reinstall -y ca-certificates   # albo skopiuj $SYSTEM_P11 z hosta z tą samą wersją RHEL"
  NEED_EXTRACT=true
fi

while IFS= read -r f; do
  [ "$f" = "$SYSTEM_P11" ] && continue
  bad "Kopia systemowego bundla w złym miejscu (p11-kit czyta ją jako dodatkowe źródło): $f"
  add_action "rm -v '$f'   # kopia systemowego bundla"
  WHOLE_FILE[$f]=1
  NEED_EXTRACT=true
done < <(find -L /etc/pki /usr/share/pki -name 'ca-bundle.trust.p11-kit*' -type f 2>/dev/null)

while IFS= read -r f; do
  bad "Wpisy 'x-distrusted' w katalogu anchors (stąd ostrzeżenie p11-kit 'certificate with distrust in location for anchors'): $f"
  [[ "$(basename "$f")" == ca-bundle.trust.p11-kit* ]] && continue   # obsłużone wyżej
  add_action "mv -v '$f' '$SRC_ETC/$BLOCK/'   # blokady należą do $BLOCK, nie do anchors"
  WHOLE_FILE[$f]=1
  NEED_EXTRACT=true
done < <(grep -rlE '^x-distrusted: *true' "$SRC_ETC/anchors" "$SRC_USR/anchors" 2>/dev/null)

for base in "$SRC_ETC" "$SRC_USR"; do
  if [ -d "$base/$OTHER_BLOCK" ] && [ -n "$(ls -A "$base/$OTHER_BLOCK" 2>/dev/null)" ]; then
    bad "Pliki w $base/$OTHER_BLOCK - na tej wersji systemu ten katalog jest IGNOROWANY, właściwy to $BLOCK"
    [ "$base" = "$SRC_ETC" ] && add_action "mkdir -p '$SRC_ETC/$BLOCK' && mv -v '$SRC_ETC/$OTHER_BLOCK'/* '$SRC_ETC/$BLOCK/'"
    NEED_EXTRACT=true
  fi
done

if [ -f "$TLS_BUNDLE" ]; then
  newer=$(find "$SRC_ETC" "$SRC_USR" -newer "$TLS_BUNDLE" 2>/dev/null | head -5)
  if [ -n "$newer" ]; then
    bad "Źródła zmienione po ostatnim 'update-ca-trust extract' - bundle jest nieaktualny:"
    sed 's/^/          /' <<< "$newer"
    NEED_EXTRACT=true
  else
    ok "Bundle aktualny względem źródeł (wygenerowany $(date -r "$TLS_BUNDLE" '+%F %T'))"
  fi
else
  bad "Brak $TLS_BUNDLE"
  NEED_EXTRACT=true
fi

if command -v rpm >/dev/null; then
  changed=$(rpm -V ca-certificates 2>&1 | grep '/usr/share/pki')
  if [ -n "$changed" ]; then
    bad "Pliki pakietu ca-certificates zmienione lub usunięte (rpm -V):"
    sed 's/^/          /' <<< "$changed"
    add_action "dnf reinstall -y ca-certificates"
  else
    ok "rpm -V ca-certificates: pliki pakietu nienaruszone"
  fi
fi

if command -v trust >/dev/null; then
  warnings=$(trust list 2>&1 >/dev/null | sort -u | head -10)
  if [ -n "$warnings" ]; then
    bad "Ostrzeżenia p11-kit (trust list):"
    sed 's/^/          /' <<< "$warnings"
  else
    ok "p11-kit nie zgłasza ostrzeżeń"
  fi
fi

# ---------------------------------------------------------------------------
# 2. Szukanie certyfikatów po nazwie
# ---------------------------------------------------------------------------
declare -A FP_SUBJ=() FP_ISS=() FP_SER=() FP_END=() FP_ENDTS=() FP_LOCS=() FP_TMP=() FILE_CERTS=()
FP_LIST=()
SCANNED=0

# Rozbija plik na pojedyncze certyfikaty; index: "plik.pem<TAB>flaga" (flaga z p11-kit: trusted/distrusted/-)
split_certs() { # plik katalog
  awk -v d="$2" '
    /^\[p11-kit-object-v1\]/      { flag = "-" }
    /^x-distrusted: *true/        { flag = "distrusted" }
    /^trusted: *true/ && flag != "distrusted" { flag = "trusted" }
    /-----BEGIN (TRUSTED )?CERTIFICATE-----/ {
      n++; out = sprintf("%s/%04d.pem", d, n); inside = 1
      print out "\t" (flag == "" ? "-" : flag) > (d "/index")
    }
    inside { print > out }
    /-----END (TRUSTED )?CERTIFICATE-----/ && inside { inside = 0; close(out) }
  ' "$1"
}

scan_file() { # plik_z_treścią ścieżka_do_pokazania kategoria
  local src=$1 shown=$2 kat=$3 d pem flag info line subj iss ser end fp
  FILE_ID=$((FILE_ID + 1))
  d="$WORK/f$FILE_ID"
  mkdir -p "$d"
  : > "$d/index"
  if grep -qE -- '-----BEGIN (TRUSTED )?CERTIFICATE-----' "$src" 2>/dev/null; then
    split_certs "$src" "$d"
  elif openssl x509 -inform DER -in "$src" -out "$d/0001.pem" 2>/dev/null; then
    printf '%s\t-\n' "$d/0001.pem" > "$d/index"
  else
    return
  fi
  FILE_CERTS[$shown]=$(wc -l < "$d/index")

  while IFS=$'\t' read -r pem flag; do
    SCANNED=$((SCANNED + 1))
    info=$(openssl x509 -in "$pem" -noout -nameopt RFC2253 -subject -issuer -serial -enddate \
             -fingerprint -sha256 2>/dev/null) || continue
    subj= iss= ser= end= fp=
    while IFS= read -r line; do
      case $line in
        subject=*)         subj=${line#subject=}; subj=${subj# } ;;
        issuer=*)          iss=${line#issuer=};   iss=${iss# } ;;
        serial=*)          ser=${line#serial=} ;;
        notAfter=*)        end=${line#notAfter=} ;;
        *[Ff]ingerprint=*) fp=${line#*=} ;;
      esac
    done <<< "$info"
    [[ "${subj,,}"$'\n'"${iss,,}" == *"${NAME,,}"* ]] || continue

    if [ -z "${FP_SUBJ[$fp]:-}" ]; then
      FP_LIST+=("$fp")
      FP_SUBJ[$fp]=$subj
      FP_ISS[$fp]=$iss
      FP_SER[$fp]=$ser
      FP_END[$fp]=$end
      FP_ENDTS[$fp]=$(date -d "$end" +%s 2>/dev/null || echo 0)
      FP_TMP[$fp]="$WORK/match_${#FP_LIST[@]}.pem"
      openssl x509 -in "$pem" -out "${FP_TMP[$fp]}" 2>/dev/null
    fi
    FP_LOCS[$fp]+="$kat"$'\t'"$shown"$'\t'"$flag"$'\n'
  done < "$d/index"
}

scan_tree() { # katalog_lub_plik kategoria_domyślna [kategoria_dla_blokad]
  local f kat
  while IFS= read -r f; do
    kat=$2
    case $f in */blocklist/*|*/blacklist/*) kat=${3:-$2} ;; esac
    scan_file "$f" "$f" "$kat"
  done < <(find -L "$1" -type f -size -20M 2>/dev/null | sort)
}

role() { # kategoria ścieżka flaga
  local r pkg
  case $1 in
    SRC_ADMIN)
      case $2 in
        "$SRC_ETC"/anchors/*) r="źródło: zaufane CA admina (anchors)" ;;
        *.p11-kit)            r="źródło: dodane przez 'trust anchor --store'" ;;
        *legacy*)             r="źródło: bundle ca-legacy" ;;
        *)                    r="źródło: CA admina bezpośrednio w $SRC_ETC" ;;
      esac ;;
    SRC_RPM)
      pkg=$(rpm -qf "$2" 2>/dev/null) || pkg="nie należy do żadnego pakietu!"
      if [ "$2" = "$SYSTEM_P11" ]; then r="źródło: systemowy magazyn Mozilli ($pkg)"
      else r="źródło: CA z pakietu RPM ($pkg)"; fi ;;
    BLOCK_ADMIN) r="BLOKADA admina" ;;
    BLOCK_RPM)   r="BLOKADA z pakietu RPM" ;;
    OUT_TLS)    r="WYNIK: bundle TLS = /etc/pki/tls/certs/ca-bundle.crt" ;;
    OUT_OPENSSL) r="WYNIK: bundle OpenSSL z atrybutami zaufania (zablokowane też tu są, jako odrzucone)" ;;
    OUT_EMAIL)   r="WYNIK: bundle S/MIME" ;;
    OUT_OBJSIGN) r="WYNIK: bundle podpisywania kodu" ;;
    OUT_JAVA)    r="WYNIK: keystore Java" ;;
    LEGACY)      r="plik SPOZA ca-trust - update-ca-trust go nie aktualizuje" ;;
    EXTRA)       r="dodatkowa ścieżka (-p) - używa go tylko aplikacja, która go wskazuje" ;;
  esac
  case $2 in */$OTHER_BLOCK/*) r="$r - ZŁY KATALOG ($OTHER_BLOCK zamiast $BLOCK)" ;; esac
  [ "$3" = distrusted ] && r="$r [x-distrusted = zablokowany]"
  echo "$r"
}

if [ -n "$NAME" ]; then
  hdr "2. Certyfikaty pasujące do: \"$NAME\""
  OUT_DIR=${OUT_DIR:-$PWD/ca_trust_$(tr -c 'A-Za-z0-9_-' '_' <<< "$NAME" | sed 's/_*$//')_$TS}
  echo "  Przeszukiwanie (to może chwilę potrwać)..."

  scan_tree "$SRC_USR" SRC_RPM BLOCK_RPM
  scan_tree "$SRC_ETC" SRC_ADMIN BLOCK_ADMIN
  [ -f "$TLS_BUNDLE" ] && scan_file "$TLS_BUNDLE" "$TLS_BUNDLE" OUT_TLS
  for pair in "openssl/ca-bundle.trust.crt OUT_OPENSSL" "pem/email-ca-bundle.pem OUT_EMAIL" \
              "pem/objsign-ca-bundle.pem OUT_OBJSIGN"; do
    f="$EXTRACTED/${pair% *}"
    [ -f "$f" ] && scan_file "$f" "$f" "${pair#* }"
  done
  if [ -f "$EXTRACTED/java/cacerts" ] && command -v keytool >/dev/null; then
    keytool -list -rfc -keystore "$EXTRACTED/java/cacerts" -storepass changeit > "$WORK/java.pem" 2>/dev/null
    scan_file "$WORK/java.pem" "$EXTRACTED/java/cacerts" OUT_JAVA
  fi
  # Prawdziwe pliki (nie symlinki) w /etc/pki/tls/certs i ścieżki zgodności, które przestały być symlinkami
  while IFS= read -r f; do scan_file "$f" "$f" LEGACY; done \
    < <(find /etc/pki/tls/certs -maxdepth 1 -type f 2>/dev/null)
  for f in "${LEGACY_PATHS[@]}"; do
    case $f in /etc/pki/tls/certs/*) continue ;; esac   # już przeszukane
    scan_tree "$f" LEGACY
  done
  for f in "${EXTRA_PATHS[@]}"; do scan_tree "$f" EXTRA; done

  echo "  Przejrzano certyfikatów: $SCANNED, unikalnych pasujących: ${#FP_LIST[@]}"

  if [ ${#FP_LIST[@]} -eq 0 ]; then
    note "Nie znaleziono certyfikatu z \"$NAME\" w subject ani issuer"
  else
    echo "  PEM-y znalezionych certyfikatów: $OUT_DIR"
    mapfile -t SORTED < <(for fp in "${FP_LIST[@]}"; do
        printf '%s\t%s\t%s\n' "${FP_SUBJ[$fp]}" "${FP_ENDTS[$fp]}" "$fp"
      done | sort -t$'\t' -k1,1 -k2,2n | cut -f3)

    # Ile ważnych wersji ma dany subject i czy któraś wersja jest zablokowana
    declare -A SUBJ_VALID=() SUBJ_BLOCKED=()
    for fp in "${FP_LIST[@]}"; do
      [ "${FP_ENDTS[$fp]}" -gt "$NOW" ] && SUBJ_VALID[${FP_SUBJ[$fp]}]=$(( ${SUBJ_VALID[${FP_SUBJ[$fp]}]:-0} + 1 ))
      if grep -qE $'^BLOCK_[A-Z]+\t[^\t]*/'"$BLOCK"$'/|\tdistrusted$' <<< "${FP_LOCS[$fp]}"; then SUBJ_BLOCKED[${FP_SUBJ[$fp]}]=1; fi
    done

    EXPIRED=0; SOON=0; VALID=0; prev_subj=""; n=0
    for fp in "${SORTED[@]}"; do
      subj=${FP_SUBJ[$fp]}
      if [ "$subj" != "$prev_subj" ]; then
        cnt=0; for x in "${FP_LIST[@]}"; do [ "${FP_SUBJ[$x]}" = "$subj" ] && cnt=$((cnt + 1)); done
        echo
        echo "  ${BLD}■ $subj${RST}"
        echo "    wersji: $cnt, ważnych: ${SUBJ_VALID[$subj]:-0}"
        prev_subj=$subj
      fi
      n=$((n + 1))
      cn=${subj#*CN=}; cn=${cn%%,*}
      pem_out="$OUT_DIR/$(printf '%02d' $n)_$(tr -c 'A-Za-z0-9._-' '_' <<< "$cn" | sed 's/_*$//')_$(tr -d ':' <<< "${fp:0:11}").pem"
      mkdir -p "$OUT_DIR" && cp "${FP_TMP[$fp]}" "$pem_out"
      days=$(( (FP_ENDTS[$fp] - NOW) / 86400 ))
      if [ "${FP_ENDTS[$fp]}" -le "$NOW" ]; then
        status="${RED}WYGASŁY $(( -days )) dni temu${RST}"; state=expired; EXPIRED=$((EXPIRED + 1))
      elif [ "$days" -le "$DAYS_WARNING" ]; then
        status="${YEL}WYGASA za $days dni${RST}"; state=soon; SOON=$((SOON + 1))
      else
        status="${GRN}ważny jeszcze $days dni${RST}"; state=valid; VALID=$((VALID + 1))
      fi
      echo
      echo "    [$n] $status   ważny do: $(date -d "${FP_END[$fp]}" '+%F' 2>/dev/null || echo "${FP_END[$fp]}")"
      echo "        serial:   ${FP_SER[$fp]}"
      echo "        SHA256:   $fp"
      [ "${FP_ISS[$fp]}" != "$subj" ] && echo "        wystawca: ${FP_ISS[$fp]}"
      echo "        PEM:      $pem_out"
      echo "        gdzie:"

      in_out=false; blocked=false; wrong_block=false; rpm_src=false; admin_src=(); legacy=()
      while IFS=$'\t' read -r kat path flag; do
        [ -n "$kat" ] || continue
        printf "          %-60s %s\n" "$path" "$(role "$kat" "$path" "$flag")"
        if [[ $kat == BLOCK_* && $path == */$OTHER_BLOCK/* ]]; then wrong_block=true; continue; fi
        if [[ $kat == BLOCK_* ]] || [ "$flag" = distrusted ]; then blocked=true; continue; fi
        case $kat in
          OUT_TLS)             in_out=true ;;
          SRC_ADMIN)           admin_src+=("$path") ;;
          SRC_RPM)             rpm_src=true ;;
          LEGACY|EXTRA)        legacy+=("$path") ;;
        esac
      done <<< "${FP_LOCS[$fp]}"

      verdict=()
      if [ "$state" = expired ] && ! $in_out && [ ${#admin_src[@]} -eq 0 ] && [ ${#legacy[@]} -eq 0 ]; then
        verdict+=("${GRN}OK${RST} - wygasły, ale nie ma go już w bundlu ani w źródłach admina")
      elif [ "$state" = expired ]; then
        if [ "${SUBJ_VALID[$subj]:-0}" -gt 0 ]; then
          verdict+=("${RED}USUŃ${RST} - wygasły, jest ważna wersja tego CA")
        else
          verdict+=("${RED}USUŃ${RST} - wygasły. UWAGA: brak ważnej wersji tego CA - nic go nie zastąpi")
        fi
        for p in "${admin_src[@]}"; do
          [ -n "${WHOLE_FILE[$p]:-}" ] && continue
          if [ "${FILE_CERTS[$p]:-0}" -le 1 ]; then
            add_action "rm -v '$p'   # [$n] ${subj%%,*}, wygasł ${FP_END[$fp]}"
          else
            verdict+=("$p - certyfikatów w pliku: ${FILE_CERTS[$p]}; usunąć tylko ten jeden blok")
            add_action "# [$n] usuń z '$p' tylko certyfikat SHA256 $fp (plik ma ${FILE_CERTS[$p]} cert.)"
          fi
          NEED_EXTRACT=true
        done
        if $rpm_src && ! $blocked; then
          verdict+=("pochodzi z pakietu RPM: wygasły CA i tak niczego nie zweryfikuje; żeby zniknął z bundli - zablokuj (nie usuwaj pliku pakietu)")
          add_action "# [$n] opcjonalnie: cp -v '$pem_out' '$SRC_ETC/$BLOCK/'"
        fi
        for p in "${legacy[@]}"; do
          [ -n "${WHOLE_FILE[$p]:-}" ] && continue
          add_action "# [$n] usuń ręcznie z '$p' (plik spoza ca-trust)"
        done
        if ! $rpm_src && [ ${#admin_src[@]} -eq 0 ] && $in_out && ! $blocked; then
          verdict+=("jest w bundlu, ale nie ma go w żadnym źródle - bundle nieaktualny")
          NEED_EXTRACT=true
        fi
      elif [ "$state" = soon ]; then
        verdict+=("${YEL}ZOSTAW${RST} - jeszcze ważny, ale przygotuj następcę")
      else
        verdict+=("${GRN}ZOSTAW${RST}")
      fi
      if $blocked && $in_out; then
        verdict+=("zablokowany, a mimo to nadal w bundlu - trzeba uruchomić update-ca-trust extract")
        NEED_EXTRACT=true
      elif $blocked; then
        verdict+=("zablokowany - nie trafia do bundla")
      elif $wrong_block; then
        verdict+=("${YEL}blokada leży w $OTHER_BLOCK - na tym systemie NIE działa (przenieś do $BLOCK)${RST}")
      elif [ -n "${SUBJ_BLOCKED[$subj]:-}" ] && $in_out; then
        verdict+=("${YEL}zablokowano INNĄ wersję tego CA (inny SHA256) - ta nadal jest w bundlu${RST}")
      fi
      echo "        werdykt:"
      for v in "${verdict[@]}"; do echo "          → $v"; done
    done

    echo
    echo "  Podsumowanie: wygasłe: ${RED}$EXPIRED${RST}, wygasające (≤${DAYS_WARNING} dni): ${YEL}$SOON${RST}, ważne: ${GRN}$VALID${RST}"
  fi
fi

# ---------------------------------------------------------------------------
# 3. Proponowane polecenia
# ---------------------------------------------------------------------------
hdr "3. Proponowane polecenia (NIC nie zostało wykonane)"
if [ ${#ACTIONS[@]} -eq 0 ] && ! $NEED_EXTRACT; then
  ok "Nic do zrobienia"
else
  echo "  # kopia zapasowa"
  echo "  tar czf /root/ca-trust-backup_$TS.tgz /etc/pki/ca-trust/source /etc/pki/tls/certs"
  for a in "${ACTIONS[@]}"; do echo "  $a"; done
  echo "  update-ca-trust extract"
  echo "  # weryfikacja"
  echo "  $0${NAME:+ \"$NAME\"}"
fi
[ "$ISSUES" -gt 0 ] && echo && echo "  Problemów w plikach systemowych: ${RED}$ISSUES${RST}"
exit 0
