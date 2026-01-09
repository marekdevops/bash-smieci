import re
import json
import os
import hashlib
import sys
import tempfile
from datetime import datetime

class TargetedAnonymizer:
    def __init__(self, dns_filter=None, ip_prefix=None):
        self.dns_filter = dns_filter
        self.ip_prefix = ip_prefix
        self.mappings = {'ip': {}, 'dns': {}, 'pv': {}}
        
        # Stały wzorzec dla pv_ (zgodnie z pierwotnym założeniem)
        self.pv_pattern = r'\bpv_[a-zA-Z0-9_\-]+\b'

    def _get_id(self, val, cat):
        if val not in self.mappings[cat]:
            short_hash = hashlib.md5(val.encode()).hexdigest()[:6]
            self.mappings[cat][val] = f"[{cat.upper()}_{short_hash}]"
        return self.mappings[cat][val]

    def anonymize_text(self, text):
        if not isinstance(text, str): return text
        
        # 1. Anonimizacja PV (zawsze)
        text = re.sub(self.pv_pattern, lambda m: self._get_id(m.group(0), 'pv'), text)
        
        # 2. Anonimizacja IP z prefixem (np. 10.10.X.X)
        if self.ip_prefix:
            # Escapujemy kropki w prefixie dla regex
            safe_prefix = self.ip_prefix.replace('.', r'\.')
            ip_pattern = rf'\b{safe_prefix}\.\d{{1,3}}\.\d{{1,3}}\b'
            text = re.sub(ip_pattern, lambda m: self._get_id(m.group(0), 'ip'), text)
            
        # 3. Anonimizacja DNS zawierającego frazę
        if self.dns_filter:
            # Szuka ciągów znaków przypominających hosty/domeny zawierające filtr
            dns_pattern = rf'\b[a-zA-Z0-9.-]*{re.escape(self.dns_filter)}[a-zA-Z0-9.-]*\b'
            text = re.sub(dns_pattern, lambda m: self._get_id(m.group(0), 'dns'), text)
            
        return text

    def save_key(self):
        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        path = os.path.join(tempfile.gettempdir(), f"anonymizer_key_{ts}.json")
        with open(path, 'w') as f:
            json.dump(self.mappings, f, indent=4)
        return path

def main():
    import argparse
    parser = argparse.ArgumentParser(description="Targeted Log Anonymizer")
    parser.add_argument("dir", help="Katalog wejściowy")
    parser.add_argument("-dns", help="Fraza w nazwie DNS do zamaskowania (np. 'firma.local')")
    parser.add_argument("-ip", help="Prefix IP do zamaskowania (np. '10.10')")
    
    args = parser.parse_args()
    
    if not os.path.isdir(args.dir):
        print(f"Błąd: {args.dir} nie istnieje.")
        return

    in_dir = args.dir.rstrip(os.sep)
    out_dir = f"{in_dir}_OUT"
    anon = TargetedAnonymizer(dns_filter=args.dns, ip_prefix=args.ip)

    print(f"[*] Start. Cel: {out_dir}")

    for root, _, files in os.walk(in_dir):
        for fname in files:
            # Przetwarzanie nazwy pliku
            new_fname = anon.anonymize_text(fname)
            
            in_p = os.path.join(root, fname)
            rel = os.path.relpath(root, in_dir)
            out_p = os.path.join(out_dir, rel, new_fname)
            
            os.makedirs(os.path.dirname(out_p), exist_ok=True)
            
            # Przetwarzanie zawartości
            _, ext = os.path.splitext(fname)
            with open(in_p, 'r', encoding='utf-8', errors='ignore') as f:
                if ext.lower() == '.json':
                    try:
                        data = json.load(f)
                        def walk_json(obj):
                            if isinstance(obj, dict): return {k: walk_json(v) for k, v in obj.items()}
                            if isinstance(obj, list): return [walk_json(i) for i in obj]
                            return anon.anonymize_text(obj)
                        res = walk_json(data)
                        with open(out_p, 'w') as o: json.dump(res, o, indent=4)
                    except: # Jeśli JSON jest uszkodzony, traktuj jak tekst
                        f.seek(0)
                        with open(out_p, 'w') as o:
                            for line in f: o.write(anon.anonymize_text(line))
                else:
                    with open(out_p, 'w') as o:
                        for line in f: o.write(anon.anonymize_text(line))
            
            print(f"  -> {fname}")

    key_path = anon.save_key()
    print(f"\n[V] Gotowe. Klucz w: {key_path}")

if __name__ == "__main__":
    main()