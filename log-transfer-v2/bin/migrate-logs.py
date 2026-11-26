#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
Migrator starych skryptów (logs_copy.sh, logs_copy2.sh, logs_mount.sh, logs.sh)
oraz wpisów cron wielu użytkowników na nowy system log-transfer-v2.

Kompatybilny z Python 2.7 (RHEL 7) oraz Python 3.x.
"""
from __future__ import print_function, unicode_literals
import argparse
import codecs
import glob
import io
import json
import os
import pwd
import re
import shutil
import subprocess
import sys
import time


def to_unicode(val):
    if sys.version_info[0] < 3 and isinstance(val, str):
        return val.decode("utf-8", "replace")
    return val


DEFAULT_PATTERNS = [
    r"(?:^|[/\s'\"])logs[A-Za-z0-9_.-]*\.sh(?:\s|$|;|&|\|)",
]

VAR_REGEX = re.compile(r'^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+?)\s*(?:#.*)?$')
CRON_LINE_RE = re.compile(r'^\s*([^\s#]+\s+[^\s]+\s+[^\s]+\s+[^\s]+\s+[^\s]+)\s+(.+)$')


def strip_quotes(val):
    val = val.strip()
    if len(val) >= 2 and ((val[0] == '"' and val[-1] == '"') or (val[0] == "'" and val[-1] == "'")):
        return val[1:-1]
    return val


def parse_old_script(script_path):
    """Wyciąga zmienne konfiguracyjne i cechy ze starego skryptu Bash."""
    info = {
        "script_path": script_path,
        "exists": os.path.isfile(script_path),
        "vars": {},
        "has_pack_logs": False,
        "has_mount": False,
        "mtime_days": "-1",
        "warnings": [],
    }
    if not info["exists"]:
        info["warnings"].append("Plik skryptu nie istnieje na dysku")
        return info

    with io.open(script_path, "r", encoding="utf-8", errors="replace") as fh:
        content = fh.read()

    if "pack_logs" in content and "send_file_to_ftp" in content:
        info["has_pack_logs"] = True
    if "mount_logsfilesystem" in content:
        info["has_mount"] = True

    m_mtime = re.search(r'find_recent_files\s+"[^"]+"\s+"([^"]+)"', content)
    if m_mtime:
        info["mtime_days"] = m_mtime.group(1)

    for line in content.splitlines():
        m = VAR_REGEX.match(line)
        if not m:
            continue
        key, raw_val = m.group(1), m.group(2)
        if key in (
            "FTP_HOST", "SFTP_HOST", "FTP_USER", "FTP_PASS",
            "FTP_REMOTE_DIR", "REMOTE_DIR", "FTP_PARALLEL", "PARALLEL",
            "TRANSFER_PROTOCOL", "search_dir", "local_mirror_dir",
            "MOUNT_FILESYSTEM", "MOUNT_SOURCE", "MOUNT_TYPE",
            "HOSTS_LOGS_LIST",
        ):
            info["vars"][key] = strip_quotes(raw_val)

    v = info["vars"]
    if not v.get("search_dir") and not v.get("local_mirror_dir"):
        info["warnings"].append("Brak search_dir i local_mirror_dir")
    if v.get("local_mirror_dir", "").startswith("/ścieżka/"):
        info["warnings"].append("Przykładowa ścieżka local_mirror_dir nie została zmieniona")
    if v.get("FTP_PASS") in ("twoje_hasło", "******", ""):
        info["warnings"].append("Hasło FTP wygląda na placeholder lub jest puste")
    return info


def resolve_script_path(cmd, user):
    """Rozwiązuje pełną ścieżkę skryptu z uwzględnieniem 'cd <katalog> && ./skrypt.sh'."""
    m_cd = re.search(r'\bcd\s+(?:"([^"]+)"|\'([^\']+)\'|([^\s;&|]+))', cmd)
    cd_dir = ""
    if m_cd:
        cd_dir = m_cd.group(1) or m_cd.group(2) or m_cd.group(3) or ""

    m_path = re.search(r'(?:"([^"]+\.sh)"|\'([^\']+\.sh)\'|([^\s;&|]+\.sh))', cmd)
    if not m_path:
        return ""
    raw_path = m_path.group(1) or m_path.group(2) or m_path.group(3) or ""

    if raw_path.startswith("~"):
        try:
            home_dir = pwd.getpwnam(user).pw_dir
            raw_path = home_dir + raw_path[1:]
        except KeyError:
            pass

    if os.path.isabs(raw_path):
        return os.path.normpath(raw_path)

    if cd_dir:
        return os.path.normpath(os.path.join(cd_dir, raw_path))

    try:
        home_dir = pwd.getpwnam(user).pw_dir
        return os.path.normpath(os.path.join(home_dir, raw_path))
    except KeyError:
        return os.path.normpath(raw_path)


def scan_crontabs(cron_dir, script_patterns):
    """Skanuje pliki crontab użytkowników w poszukiwaniu starych skryptów."""
    compiled = [re.compile(p) for p in script_patterns]
    findings = []

    if not os.path.isdir(cron_dir):
        return findings

    for cron_file in sorted(glob.glob(os.path.join(cron_dir, "*"))):
        if not os.path.isfile(cron_file):
            continue
        user = os.path.basename(cron_file)
        with io.open(cron_file, "r", encoding="utf-8", errors="replace") as fh:
            lines = fh.readlines()

        for idx, line in enumerate(lines, 1):
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue
            m = CRON_LINE_RE.match(stripped)
            if not m:
                continue
            schedule, cmd = m.group(1), m.group(2)
            if "log-transfer.sh" in cmd:
                continue
            for pat in compiled:
                if pat.search(cmd):
                    script_path = resolve_script_path(cmd, user)
                    findings.append({
                        "user": user,
                        "cron_file": cron_file,
                        "line_no": idx,
                        "schedule": schedule,
                        "command": cmd,
                        "script_path": script_path,
                    })
                    break
    return findings


def build_job_id(user, script_path, existing_ids):
    base = os.path.splitext(os.path.basename(script_path))[0] if script_path else "job"
    raw = "%s_%s" % (user, base)
    clean = re.sub(r'[^a-zA-Z0-9_-]+', '_', raw)
    candidate = clean
    idx = 2
    while candidate in existing_ids:
        candidate = "%s_%d" % (clean, idx)
        idx += 1
    existing_ids.add(candidate)
    return candidate


def render_config(template_text, job_id, user, base_dir, parsed):
    v = parsed["vars"]
    search_dir = v.get("search_dir", "")
    mirror_dir = v.get("local_mirror_dir", "")
    mode = "search" if search_dir else "mirror"
    remote_dir = v.get("FTP_REMOTE_DIR") or v.get("REMOTE_DIR") or "/remote/logs"
    proto = v.get("TRANSFER_PROTOCOL", "ftp").lower()
    if proto not in ("ftp", "ftps", "sftp"):
        proto = "ftp"
    parallel = v.get("FTP_PARALLEL") or v.get("PARALLEL") or "4"
    hosts_list = v.get("HOSTS_LOGS_LIST", "()")
    if not hosts_list.startswith("("):
        hosts_list = "(%s)" % hosts_list

    replacements = {
        "JOB_ID": '"%s"' % job_id,
        "JOB_DESCRIPTION": '"Zmigrowane z %s (user: %s)"' % (parsed["script_path"], user),
        "OWNER_USER": '"%s"' % user,
        "BASE_DIR": '"%s"' % base_dir,
        "TRANSFER_MODE": '"%s"' % mode,
        "SEARCH_DIR": '"%s"' % search_dir,
        "SEARCH_MTIME_DAYS": '"%s"' % parsed["mtime_days"],
        "LOCAL_MIRROR_DIR": '"%s"' % mirror_dir,
        "HOSTS_LOGS_LIST": hosts_list,
        "MOUNT_FILESYSTEM": '"%s"' % v.get("MOUNT_FILESYSTEM", "false").lower(),
        "MOUNT_SOURCE": '"%s"' % v.get("MOUNT_SOURCE", ""),
        "MOUNT_TYPE": '"%s"' % v.get("MOUNT_TYPE", "ext4"),
        "MOUNT_TARGET": '"%s"' % search_dir,
        "PACK_ARCHIVE": '"%s"' % ("true" if parsed["has_pack_logs"] else "false"),
        "TRANSFER_PROTOCOL": '"%s"' % proto,
        "FTP_HOST": '"%s"' % v.get("FTP_HOST", "ftp.example.com"),
        "SFTP_HOST": '"%s"' % v.get("SFTP_HOST", ""),
        "FTP_USER": '"%s"' % v.get("FTP_USER", "loguser"),
        "CREDENTIALS_FILE": '"%s/etc/creds/%s.pass"' % (base_dir, job_id),
        "REMOTE_DIR": '"%s"' % remote_dir,
        "FTP_PARALLEL": '"%s"' % parallel,
    }

    out_lines = []
    for line in template_text.splitlines():
        m = re.match(r'^([A-Z0-9_]+)=', line)
        if m and m.group(1) in replacements:
            key = m.group(1)
            out_lines.append("%s=%s" % (key, replacements[key]))
        else:
            out_lines.append(line)
    return "\n".join(out_lines) + "\n"


def safe_chown(path, user):
    if os.geteuid() != 0:
        return
    try:
        pw = pwd.getpwnam(user)
        os.chown(path, pw.pw_uid, pw.pw_gid)
    except KeyError:
        pass


def cmd_rollback(base_dir, timestamp, cron_dir):
    backup_dir = os.path.join(base_dir, "backups", timestamp)
    if not os.path.isdir(backup_dir):
        print("BŁĄD: Brak katalogu kopii zapasowej: %s" % backup_dir, file=sys.stderr)
        return 1

    cron_backups = glob.glob(os.path.join(backup_dir, "cron_*.bak"))
    if not cron_backups:
        print("Brak kopii crontabów w %s" % backup_dir)
        return 1

    for bak in cron_backups:
        user = os.path.basename(bak)[len("cron_"):-len(".bak")]
        target_cron = os.path.join(cron_dir, user)
        if os.geteuid() == 0 and cron_dir == "/var/spool/cron":
            subprocess.check_call(["crontab", "-u", user, bak])
        else:
            shutil.copy2(bak, target_cron)
        print("Przywrócono crontab użytkownika: %s" % user)
    return 0


def prompt_input(msg):
    if sys.version_info[0] < 3:
        return raw_input(msg)  # noqa: F821
    return input(msg)


def select_plan_interactive(plan):
    """Pozwala użytkownikowi wybrać numery zadań z listy skanowania."""
    while True:
        raw = prompt_input(
            "\nWybierz numery zadań do migracji (np. 1,3 lub 1-3, 'all', 'q' aby anulować): "
        ).strip().lower()
        if raw in ("q", "quit", "exit", ""):
            return []
        if raw == "all":
            return list(plan)

        selected_indices = set()
        valid = True
        for part in raw.split(","):
            part = part.strip()
            if not part:
                continue
            if "-" in part:
                bounds = part.split("-", 1)
                if len(bounds) == 2 and bounds[0].isdigit() and bounds[1].isdigit():
                    start, end = int(bounds[0]), int(bounds[1])
                    if 1 <= start <= end <= len(plan):
                        for idx in range(start, end + 1):
                            selected_indices.add(idx - 1)
                        continue
                valid = False
                break
            elif part.isdigit():
                idx = int(part)
                if 1 <= idx <= len(plan):
                    selected_indices.add(idx - 1)
                    continue
            valid = False
            break

        if valid and selected_indices:
            return [plan[i] for i in sorted(selected_indices)]
        print("Nieprawidłowy wybór. Podaj numery od 1 do %d." % len(plan))


def main():
    if sys.version_info[0] < 3:
        sys.stdout = codecs.getwriter("utf-8")(sys.stdout)
        sys.stderr = codecs.getwriter("utf-8")(sys.stderr)

    parser = argparse.ArgumentParser(description="Migrator log-transfer-v2 dla RHEL 7")
    parser.add_argument("--cron-dir", default="/var/spool/cron", help="Katalog crontabów użytkowników")
    parser.add_argument("--base-dir", default="/opt/log-transfer", help="Docelowy katalog log-transfer-v2")
    parser.add_argument("--template", default="", help="Ścieżka do template.conf")
    parser.add_argument("--scan", action="store_true", help="Tylko skanuj i wypisz raport")
    parser.add_argument("--dry-run", action="store_true", help="Symuluj migrację bez zapisu zmian")
    parser.add_argument("--apply", action="store_true", help="Wykonaj migrację i podmień crontaby")
    parser.add_argument("-i", "--interactive", action="store_true", help="Tryb interaktywny: skanuj i wybierz zadania z listy")
    parser.add_argument("--job-id", default="", help="Filtruj po JOB_ID (rozdzielone przecinkiem)")
    parser.add_argument("--user", default="", help="Filtruj po użytkowniku crona")
    parser.add_argument("--pattern", action="append", default=[], help="Dodatkowy regex dla nazw skryptów (można powtarzać)")
    parser.add_argument("--all-sh", action="store_true", help="Skanuj wszystkie skrypty *.sh w cronie")
    parser.add_argument("--rollback", default="", help="Przywróć crontaby z podanego timestampu backupu")
    args = parser.parse_args()
    args.cron_dir = to_unicode(args.cron_dir)
    args.base_dir = to_unicode(args.base_dir)
    args.template = to_unicode(args.template)
    args.job_id = to_unicode(args.job_id)
    args.user = to_unicode(args.user)
    args.rollback = to_unicode(args.rollback)

    if args.rollback:
        return cmd_rollback(args.base_dir, args.rollback, args.cron_dir)

    if not (args.scan or args.dry_run or args.apply or args.interactive):
        parser.print_help()
        return 2

    template_path = args.template or os.path.join(args.base_dir, "etc", "template.conf")
    if (args.dry_run or args.apply or args.interactive) and not os.path.isfile(template_path):
        print("BŁĄD: Nie znaleziono szablonu: %s" % template_path, file=sys.stderr)
        return 1

    patterns = [r"\.sh(?:\s|$|;|&|\|)"] if args.all_sh else (DEFAULT_PATTERNS + args.pattern)
    findings = scan_crontabs(args.cron_dir, patterns)
    if not findings:
        print("Nie znaleziono starych skryptów w %s" % args.cron_dir)
        return 0

    template_text = ""
    if os.path.isfile(template_path):
        with io.open(template_path, "r", encoding="utf-8") as fh:
            template_text = fh.read()

    existing_ids = set()
    plan = []
    for item in findings:
        parsed = parse_old_script(item["script_path"])
        job_id = build_job_id(item["user"], item["script_path"], existing_ids)
        plan.append({
            "finding": item,
            "parsed": parsed,
            "job_id": job_id,
        })

    if args.user:
        plan = [e for e in plan if e["finding"]["user"] == args.user]
    if args.job_id:
        wanted = set(x.strip() for x in args.job_id.split(",") if x.strip())
        plan = [e for e in plan if e["job_id"] in wanted]

    if not plan:
        print("Brak zadań spełniających podane kryteria filtrowania.")
        return 0

    print("=== WYNIK SKANOWANIA (%d zadań) ===" % len(plan))
    for idx, entry in enumerate(plan, 1):
        f = entry["finding"]
        p = entry["parsed"]
        print("[%d] %s | user=%s | schedule='%s' | script=%s" % (
            idx, entry["job_id"], f["user"], f["schedule"], f["script_path"]
        ))
        if p["warnings"]:
            for w in p["warnings"]:
                print("    OSTRZEŻENIE: %s" % w)

    if args.scan and not args.interactive:
        return 0

    if args.interactive:
        plan = select_plan_interactive(plan)
        if not plan:
            print("Anulowano migrację.")
            return 0
        if not (args.dry_run or args.apply):
            mode = prompt_input("Tryb wykonania: [d] dry-run (symulacja), [a] apply (migracja), [q] anuluj: ").strip().lower()
            if mode == "d":
                args.dry_run = True
            elif mode == "a":
                args.apply = True
            else:
                print("Anulowano migrację.")
                return 0

    ts = time.strftime("%Y%m%d_%H%M%S")
    backup_dir = os.path.join(args.base_dir, "backups", ts)
    jobs_dir = os.path.join(args.base_dir, "etc", "jobs")
    creds_dir = os.path.join(args.base_dir, "etc", "creds")

    if args.apply:
        for d in (backup_dir, jobs_dir, creds_dir):
            if not os.path.isdir(d):
                os.makedirs(d)
        os.chmod(creds_dir, 0o750)

    # Grupowanie podmian per plik crontab
    cron_updates = {}
    for entry in plan:
        f = entry["finding"]
        p = entry["parsed"]
        job_id = entry["job_id"]
        conf_path = os.path.join(jobs_dir, "%s.conf" % job_id)
        cred_path = os.path.join(creds_dir, "%s.pass" % job_id)
        new_cmd = "%s/bin/log-transfer.sh --config %s" % (args.base_dir, conf_path)
        new_cron_line = "%s %s\n" % (f["schedule"], new_cmd)

        conf_content = render_config(template_text, job_id, f["user"], args.base_dir, p)
        ftp_pass = p["vars"].get("FTP_PASS", "")

        if args.dry_run:
            print("\n[DRY-RUN] Plik: %s" % conf_path)
            print("[DRY-RUN] Hasło: %s (chmod 0600, owner=%s)" % (cred_path, f["user"]))
            print("[DRY-RUN] Nowy wpis cron (%s): %s" % (f["user"], new_cron_line.strip()))
            continue

        # Zapis konfiguracji
        with io.open(conf_path, "w", encoding="utf-8") as fh:
            if sys.version_info[0] < 3 and isinstance(conf_content, str):
                conf_content = conf_content.decode("utf-8")
            fh.write(conf_content)
        os.chmod(conf_path, 0o640)
        safe_chown(conf_path, f["user"])

        # Zapis pliku poświadczeń
        with io.open(cred_path, "w", encoding="utf-8") as fh:
            pass_u = ftp_pass.decode("utf-8") if (sys.version_info[0] < 3 and isinstance(ftp_pass, str)) else ftp_pass
            fh.write(pass_u + u"\n")
        os.chmod(cred_path, 0o600)
        safe_chown(cred_path, f["user"])

        # Backup starego skryptu
        if p["exists"]:
            shutil.copy2(f["script_path"], os.path.join(backup_dir, "%s.bak" % job_id))

        cron_updates.setdefault(f["cron_file"], {"user": f["user"], "lines": {}})
        cron_updates[f["cron_file"]]["lines"][f["line_no"]] = new_cron_line

    if args.apply:
        for cron_file, data in cron_updates.items():
            user = data["user"]
            shutil.copy2(cron_file, os.path.join(backup_dir, "cron_%s.bak" % user))
            with io.open(cron_file, "r", encoding="utf-8", errors="replace") as fh:
                orig_lines = fh.readlines()
            new_lines = []
            for idx, line in enumerate(orig_lines, 1):
                if idx in data["lines"]:
                    new_lines.append("# [MIGRATED %s] %s" % (ts, line))
                    new_lines.append(data["lines"][idx])
                else:
                    new_lines.append(line)
            new_cron_text = "".join(new_lines)
            if os.geteuid() == 0 and args.cron_dir == "/var/spool/cron":
                proc = subprocess.Popen(["crontab", "-u", user, "-"], stdin=subprocess.PIPE)
                proc.communicate(new_cron_text.encode("utf-8"))
                if proc.returncode != 0:
                    raise RuntimeError("Błąd aktualizacji crontaba dla %s" % user)
            else:
                with io.open(cron_file, "w", encoding="utf-8") as fh:
                    if sys.version_info[0] < 3 and isinstance(new_cron_text, str):
                        new_cron_text = new_cron_text.decode("utf-8")
                    fh.write(new_cron_text)
        print("\nMigracja zakończona. Backup zapisany w: %s" % backup_dir)
        print("W razie potrzeby cofnij zmiany: --rollback %s" % ts)

    return 0


if __name__ == "__main__":
    sys.exit(main())
