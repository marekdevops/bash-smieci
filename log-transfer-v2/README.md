# log-transfer-v2 (RHEL 7 / Zabbix 7 / Bank-Grade)

Kompleksowy system bezpiecznego transferu logów do partnerów zewnętrznych (FTP / FTPS / SFTP) zaprojektowany dla **Red Hat Enterprise Linux 7** bez użycia zewnętrznych repozytoriów.

## Struktura
- `bin/log-transfer.sh` — główny silnik (blokady `flock`, `umask 027`, audyt `syslog`, brak haseł w `ps aux`).
- `bin/lib/collector.sh` — montowanie z retry, strumieniowe pobieranie po SSH (`tar`), równoległa kompresja `gzip -6`, opcjonalne `gpg`.
- `bin/lib/transport.sh` — obsługa `ftp` (zwykły FTP z izolowanym plikiem komend `0600`), `ftps` (TLS + weryfikacja CA), `sftp` (klucze SSH).
- `bin/lib/json_report.py` — atomowe generowanie raportów `<job_id>.json` oraz `summary.json` (Python 2.7 / 3.x stdlib).
- `bin/migrate-logs.py` — migrator starych skryptów i crontabów wielu użytkowników (`--scan`, `--dry-run`, `--apply`, `--rollback`).
- `dashboard/` — statyczny panel WWW (HTML5/CSS3/JS, zero zewnętrznych zależności) dla `httpd`.
- `zabbix/zabbix7_template_log_transfer.yaml` — gotowy szablon dla **Zabbix 7.0 LTS** (Master Item + LLD + Triggery).

## Szybki start na RHEL 7
1. Upewnij się, że masz pakiety z oficjalnego repo RHEL 7:
   ```bash
   yum install -y lftp rsync httpd mod_ssl python
   ```
2. Uruchom instalator jako `root`:
   ```bash
   chmod +x install.sh && ./install.sh
   ```
3. Przeskanuj obecne crontaby i wybierz zadania interaktywnie (lub wykonaj próbę dla wszystkich):
   ```bash
   python /opt/log-transfer/bin/migrate-logs.py --interactive
   # lub bez interakcji:
   python /opt/log-transfer/bin/migrate-logs.py --scan
   python /opt/log-transfer/bin/migrate-logs.py --dry-run --job-id marek_logs_copy2
   ```
4. Po weryfikacji wdróż migrację:
   ```bash
   python /opt/log-transfer/bin/migrate-logs.py --apply
   ```
5. Włącz dashboard i API JSON:
   ```bash
   systemctl enable --now httpd
   ```
6. Zaimportuj `zabbix/zabbix7_template_log_transfer.yaml` w Zabbix 7 i podepnij do hosta.
