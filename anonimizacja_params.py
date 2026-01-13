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
        # Słownik przechowujący mapowania: oryginał -> ID
        self.mappings = {'ip': {}, 'dns': {}, 'pv': {}}
        
        # Stały wzorzec dla wolumenów pv_*
        self.pv_pattern = r'\bpv_[a-zA-Z0-9_\-]+\b'

    def _get_id(self, val, cat):
        """Generuje stały identyfikator dla danej wartości w danej kategorii."""
        val = val.lower().strip()
        if val not in self.mappings[cat]:
            short_hash = hashlib.md5(val.encode()).hexdigest()[:6]
            self.mappings[cat][val] = f"[{cat.upper()}_{short_hash}]"
        return self.mappings[cat][val]

    def anonymize_text(self, text):
        if not isinstance(text, str):
            return text
        
        # 1. PV (zawsze)
        text = re.sub(self.pv_pattern, lambda m: self._get_id(m.group(0), 'pv'), text)
        
        # 2. IP z prefixem
        if self.ip_prefix:
            safe_prefix = self.ip_prefix.replace('.', r'\.')
            ip_pattern = rf'\b({safe_prefix}\.\d{{1,3}}\.\d{{1,3}})\b'
            text = re.sub(ip_pattern, lambda m: self._get_id(m.group(1), 'ip'), text)
            
        # 3. DNS (odporny na kropki ORAZ myślniki)
        if self.dns_filter:
            # Tworzymy wersję filtra z myślnikami (np. moja-domena-pl)
            dns_hyphenated = self.dns_filter.replace('.', '-')
            
            # Budujemy regex, który szuka OBU wariantów
            # Szukamy ciągu alfanumerycznego, który zawiera kropki LUB myślniki
            combined_filter = f"({re.escape(self.dns_filter)}|{re.escape(dns_hyphenated)})"
            dns_pattern = rf'([a-zA-Z0-9.-]*{combined_filter}[a-zA-Z0-9]*)'
            
            def dns_replacer(match):
                full_match = match.group(1)
                clean_dns = full_match.strip('.-')
                suffix = full_match[len(clean_dns):]
                
                # KLUCZ: Normalizujemy wartość przed pobraniem ID.
                # Zamieniamy wszystkie myślniki na kropki, aby worker-domena-pl 
                # i worker.domena.pl dostały TEN SAM hash.
                normalized_val = clean_dns.replace('-', '.')
                
                return self._get_id(normalized_val, 'dns') + suffix

            text = re.sub(dns_pattern, dns_replacer, text)
            
        return text

    def save_key(self):
        """Zapisuje mapowanie do pliku JSON w katalogu tymczasowym systemu."""
        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        tmp_dir = tempfile.gettempdir()
        path = os.path.join(tmp_dir, f"anonymizer_key_{ts}.json")
        
        # Przygotowanie czytelnego formatu: ID -> Oryginalna wartość
        readable_map = {
            cat: {v: k for k, v in res.items()} 
            for cat, res in self.mappings.items()
        }
        
        with open(path, 'w', encoding='utf-8') as f:
            json.dump(readable_map, f, indent=4)
        return path

def main():
    import argparse
    parser = argparse.ArgumentParser(description="Targeted Log Anonymizer")
    parser.add_argument("dir", help="Katalog z plikami do anonimizacji")
    parser.add_argument("-dns", help="Fraza w nazwie DNS (np. 'moja.domena.pl')")
    parser.add_argument("-ip", help="Prefix IP (np. '10.10')")
    
    args = parser.parse_args()
    
    if not os.path.isdir(args.dir):
        print(f"Błąd: Katalog {args.dir} nie istnieje.")
        return

    input_dir = args.dir.rstrip(os.sep)
    output_dir = f"{input_dir}_OUT"
    anon = TargetedAnonymizer(dns_filter=args.dns, ip_prefix=args.ip)

    print(f"[*] Rozpoczynam anonimizację katalogu: {input_dir}")
    print(f"[*] Wyniki zostaną zapisane w: {output_dir}")

    for root, _, files in os.walk(input_dir):
        for fname in files:
            # Anonimizacja nazwy pliku
            new_fname = anon.anonymize_text(fname)
            
            in_path = os.path.join(root, fname)
            rel_path = os.path.relpath(root, input_dir)
            out_path = os.path.join(output_dir, rel_path, new_fname)
            
            os.makedirs(os.path.dirname(out_path), exist_ok=True)
            
            try:
                with open(in_path, 'r', encoding='utf-8', errors='ignore') as f:
                    content = f.read()
                    
                # Obsługa formatu JSON
                if fname.lower().endswith('.json'):
                    try:
                        data = json.loads(content)
                        def walk(obj):
                            if isinstance(obj, dict): return {k: walk(v) for k, v in obj.items()}
                            if isinstance(obj, list): return [walk(i) for i in obj]
                            if isinstance(obj, str): return anon.anonymize_text(obj)
                            return obj
                        
                        processed_content = json.dumps(walk(data), indent=4)
                    except:
                        processed_content = anon.anonymize_text(content)
                else:
                    processed_content = anon.anonymize_text(content)

                with open(out_path, 'w', encoding='utf-8') as f:
                    f.write(processed_content)
                
                print(f"  [OK] {fname} -> {new_fname}")
            except Exception as e:
                print(f"  [!] Błąd podczas przetwarzania {fname}: {e}")

    key_path = anon.save_key()
    print("\n" + "="*50)
    print(f"SUKCES! Pliki zanonimizowano w: {output_dir}")
    print(f"KLUCZ DEKODUJĄCY ZAPISANO W: {key_path}")
    print("="*50)

if __name__ == "__main__":
    main()