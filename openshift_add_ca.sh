#!/usr/bin/env bash
# Dodanie certyfikatów CA do zaufanego bundla całego klastra OpenShift 4.x
# (proxy/cluster -> spec.trustedCA -> ConfigMap w openshift-config, klucz ca-bundle.crt).
#
# Istniejące certyfikaty w bundlu są ZACHOWYWANE - dopisywane są tylko te, których
# jeszcze nie ma (porównanie po fingerprincie SHA-256). Przed zmianą robiona jest kopia.
#
# Wymaga: oc (zalogowany do klastra, uprawnienia cluster-admin), openssl.
#
# Użycie:
#   ./openshift_add_ca.sh                 # certyfikaty z CERT_FILES poniżej
#   ./openshift_add_ca.sh -n              # dry run - tylko pokazuje, co by zrobił
#   ./openshift_add_ca.sh -y a.crt b.crt  # inne pliki, bez pytania o potwierdzenie

set -euo pipefail

# --- Certyfikaty do dodania (PEM lub DER; plik może zawierać kilka certyfikatów) ---
CERT_FILES=(
  /home/marek/certs/root_ca.crt
  /home/marek/certs/intermediate_ca.crt
)

# Nazwa ConfigMapy tworzonej, gdy klaster nie ma jeszcze ustawionego trustedCA
DEFAULT_CM_NAME="user-ca-bundle"
CM_NS="openshift-config"
BACKUP_DIR="${BACKUP_DIR:-$PWD}"
WAIT_SECONDS=180

DRY_RUN=false
ASSUME_YES=false

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
log()   { echo "[$(date +%H:%M:%S)] $*"; }
warn()  { echo "[$(date +%H:%M:%S)] UWAGA: $*" >&2; }
die()   { echo "[$(date +%H:%M:%S)] BŁĄD: $*" >&2; exit 1; }

while getopts ":nyh" opt; do
  case "$opt" in
    n) DRY_RUN=true ;;
    y) ASSUME_YES=true ;;
    h) usage 0 ;;
    *) usage 1 ;;
  esac
done
shift $((OPTIND - 1))
if [ $# -gt 0 ]; then CERT_FILES=("$@"); fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fingerprint() { openssl x509 -in "$1" -noout -fingerprint -sha256 | cut -d= -f2; }

# Rozbija plik PEM na pojedyncze certyfikaty: $1 - plik, $2 - katalog, $3 - prefiks
split_pem() {
  awk -v d="$2" -v p="$3" '
    /-----BEGIN CERTIFICATE-----/ { n++; f = sprintf("%s/%s%04d.pem", d, p, n); inside = 1 }
    inside { print > f }
    /-----END CERTIFICATE-----/   { inside = 0; close(f) }
  ' "$1"
}

# ---------------------------------------------------------------------------
# 1. Kontrola środowiska
# ---------------------------------------------------------------------------
command -v oc >/dev/null      || die "Brak polecenia oc"
command -v openssl >/dev/null || die "Brak polecenia openssl"

oc whoami >/dev/null 2>&1 || die "Nie jesteś zalogowany do klastra (oc login ...)"
log "Klaster: $(oc whoami --show-server)  użytkownik: $(oc whoami)"

for check in "patch proxies.config.openshift.io/cluster" \
             "update configmaps -n $CM_NS" \
             "create configmaps -n $CM_NS" \
             "get configmaps -n openshift-config-managed"; do
  # shellcheck disable=SC2086
  oc auth can-i $check >/dev/null 2>&1 || die "Brak uprawnień: oc auth can-i $check"
done

# ---------------------------------------------------------------------------
# 2. Walidacja nowych certyfikatów
# ---------------------------------------------------------------------------
mkdir -p "$WORK/new" "$WORK/old"
for f in "${CERT_FILES[@]}"; do
  [ -f "$f" ] || die "Brak pliku: $f"
  base=$(basename "$f" | tr -c 'A-Za-z0-9._\n-' '_')
  if grep -q -- "-----BEGIN CERTIFICATE-----" "$f"; then
    split_pem "$f" "$WORK/new" "${base}_"
  elif openssl x509 -inform DER -in "$f" -out "$WORK/new/${base}_0001.pem" 2>/dev/null; then
    log "$f: format DER - skonwertowano do PEM"
  else
    die "$f: to nie jest certyfikat X.509 (PEM ani DER)"
  fi
done

NEW_CERTS=("$WORK"/new/*.pem)
[ -e "${NEW_CERTS[0]}" ] || die "Nie znaleziono żadnych certyfikatów w podanych plikach"

for c in "${NEW_CERTS[@]}"; do
  openssl x509 -in "$c" -noout 2>/dev/null || die "Uszkodzony certyfikat w $(basename "$c")"
  subj=$(openssl x509 -in "$c" -noout -subject | sed 's/^subject= *//')
  openssl x509 -in "$c" -noout -checkend 0 >/dev/null || warn "WYGASŁ: $subj"
  openssl x509 -in "$c" -noout -text | grep -q "CA:TRUE" || warn "To nie jest certyfikat CA (brak CA:TRUE): $subj"
done

# ---------------------------------------------------------------------------
# 3. Pobranie aktualnego bundla z klastra
# ---------------------------------------------------------------------------
CM_NAME=$(oc get proxy/cluster -o jsonpath='{.spec.trustedCA.name}')
PROXY_NEEDS_PATCH=false
CM_EXISTS=false

if [ -n "$CM_NAME" ]; then
  log "proxy/cluster używa ConfigMapy: $CM_NS/$CM_NAME"
else
  CM_NAME="$DEFAULT_CM_NAME"
  PROXY_NEEDS_PATCH=true
  log "proxy/cluster nie ma ustawionego trustedCA - zostanie ustawione na $CM_NS/$CM_NAME"
fi

: > "$WORK/bundle.crt"
if oc get configmap "$CM_NAME" -n "$CM_NS" >/dev/null 2>&1; then
  CM_EXISTS=true
  oc get configmap "$CM_NAME" -n "$CM_NS" -o jsonpath='{.data.ca-bundle\.crt}' > "$WORK/bundle.crt"
  split_pem "$WORK/bundle.crt" "$WORK/old" "old_"
fi

declare -A KNOWN=()
OLD_COUNT=0
for c in "$WORK"/old/*.pem; do
  [ -e "$c" ] || continue
  KNOWN["$(fingerprint "$c")"]=1
  OLD_COUNT=$((OLD_COUNT + 1))
done
log "Certyfikatów w obecnym bundlu: $OLD_COUNT"

# ---------------------------------------------------------------------------
# 4. Wybór certyfikatów do dopisania
# ---------------------------------------------------------------------------
TO_ADD=()
for c in "${NEW_CERTS[@]}"; do
  fp=$(fingerprint "$c")
  subj=$(openssl x509 -in "$c" -noout -subject | sed 's/^subject= *//')
  if [ -n "${KNOWN[$fp]:-}" ]; then
    log "  już jest:  $subj"
  else
    log "  DO DODANIA: $subj  (wygasa: $(openssl x509 -in "$c" -noout -enddate | cut -d= -f2))"
    TO_ADD+=("$c")
    KNOWN["$fp"]=1   # duplikaty między podanymi plikami
  fi
done

if [ ${#TO_ADD[@]} -eq 0 ]; then
  log "Wszystkie certyfikaty są już w bundlu - nic do zrobienia."
  exit 0
fi

# Nowy bundle = stary bundle (bez zmian) + nowe certyfikaty na końcu
cp "$WORK/bundle.crt" "$WORK/bundle.new"
if [ -s "$WORK/bundle.new" ] && [ -n "$(tail -c1 "$WORK/bundle.new")" ]; then echo >> "$WORK/bundle.new"; fi
cat "${TO_ADD[@]}" >> "$WORK/bundle.new"

NEW_COUNT=$(grep -c -- "-----BEGIN CERTIFICATE-----" "$WORK/bundle.new")
log "Nowy bundle: $NEW_COUNT certyfikatów ($OLD_COUNT dotychczasowych + ${#TO_ADD[@]} nowych)"

if $DRY_RUN; then
  log "DRY RUN - na klastrze nic nie zostało zmienione."
  if $CM_EXISTS; then
    log "  zaktualizowana zostałaby ConfigMapa $CM_NS/$CM_NAME"
  else
    log "  utworzona zostałaby ConfigMapa $CM_NS/$CM_NAME"
  fi
  if $PROXY_NEEDS_PATCH; then
    log "  proxy/cluster: spec.trustedCA.name zostałoby ustawione na $CM_NAME"
  fi
  exit 0
fi

if ! $ASSUME_YES; then
  echo
  echo "Zmiana dotyczy CAŁEGO klastra (Machine Config Operator rozprowadzi bundle na wszystkie węzły)."
  read -r -p "Kontynuować? [t/N] " ans
  [[ "$ans" =~ ^[tTyY]$ ]] || die "Przerwano przez użytkownika"
fi

# ---------------------------------------------------------------------------
# 5. Kopia zapasowa i zapis zmian
# ---------------------------------------------------------------------------
TS=$(date +%Y%m%d_%H%M%S)
oc get proxy/cluster -o yaml > "$BACKUP_DIR/backup_proxy_cluster_$TS.yaml"
log "Kopia proxy/cluster: $BACKUP_DIR/backup_proxy_cluster_$TS.yaml"
if $CM_EXISTS; then
  oc get configmap "$CM_NAME" -n "$CM_NS" -o yaml > "$BACKUP_DIR/backup_${CM_NAME}_$TS.yaml"
  log "Kopia ConfigMapy:  $BACKUP_DIR/backup_${CM_NAME}_$TS.yaml"
fi

if $CM_EXISTS; then
  # set data zmienia tylko klucz ca-bundle.crt - pozostałe klucze i etykiety zostają
  oc set data configmap/"$CM_NAME" -n "$CM_NS" --from-file=ca-bundle.crt="$WORK/bundle.new"
else
  oc create configmap "$CM_NAME" -n "$CM_NS" --from-file=ca-bundle.crt="$WORK/bundle.new"
fi

if $PROXY_NEEDS_PATCH; then
  oc patch proxy/cluster --type=merge -p "{\"spec\":{\"trustedCA\":{\"name\":\"$CM_NAME\"}}}"
fi

# ---------------------------------------------------------------------------
# 6. Weryfikacja: czy nowe CA trafiły do scalonego bundla klastra
# ---------------------------------------------------------------------------
log "Czekam (max ${WAIT_SECONDS}s), aż nowe CA pojawią się w openshift-config-managed/trusted-ca-bundle..."
deadline=$((SECONDS + WAIT_SECONDS))
while :; do
  rm -rf "$WORK/merged"; mkdir -p "$WORK/merged"
  oc get configmap trusted-ca-bundle -n openshift-config-managed \
     -o jsonpath='{.data.ca-bundle\.crt}' > "$WORK/merged.crt" 2>/dev/null || true
  split_pem "$WORK/merged.crt" "$WORK/merged" "m_"
  declare -A MERGED=()
  for c in "$WORK"/merged/*.pem; do
    if [ -e "$c" ]; then MERGED["$(fingerprint "$c")"]=1; fi
  done
  missing=0
  for c in "${TO_ADD[@]}"; do
    if [ -z "${MERGED[$(fingerprint "$c")]:-}" ]; then missing=$((missing + 1)); fi
  done
  unset MERGED
  if [ $missing -eq 0 ]; then
    log "OK - wszystkie nowe CA są w trusted-ca-bundle."
    break
  fi
  if [ $SECONDS -ge $deadline ]; then
    warn "Po ${WAIT_SECONDS}s brakuje jeszcze $missing CA w trusted-ca-bundle."
    warn "Sprawdź: oc get co network ; oc logs -n openshift-network-operator deploy/network-operator | grep -i proxy"
    break
  fi
  sleep 10
done

echo
log "Gotowe. Rozprowadzanie na węzły obserwuj poleceniem:  oc get mcp -w"
log "Wycofanie: oc replace -f <plik kopii ConfigMapy> (i ewentualnie proxy/cluster)."
