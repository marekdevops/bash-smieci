import re
import json
import os
import hashlib
import sys
from datetime import datetime
import tempfile

class LogAnonymizer:
    def __init__(self):
        # Słownik: kategoria -> { oryginalna_wartosc: identyfikator }
        self.mappings = {'ip_address': {}, 'pv_volume': {}, 'dns_name': {}}
        
        self.patterns = {
            'ip_address': r'\b(?:\d{1,3}\.){3}\d{1,3}\b',
            'pv_volume': r'\bpv_[a-zA-Z0-9_\-]+\b',
            'dns_name': r'\b(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,6}\b'
        }

    def _get_consistent_id(self, val, cat):
        if val not in self.mappings[cat]:
            short_hash = hashlib.md5(val.encode()).hexdigest()[:6]
            self.mappings[cat][val] = f"[{cat.upper()}_{short_hash}]"
        return self.mappings[cat][val]

    def mask_text(self, text):
        if not isinstance(text, str): return text
        for cat, pat in self.patterns.items():
            text = re.sub(pat, lambda m: self._get_consistent_id(m.group(0), cat), text)
        return text

    def save_mapping_to_tmp(self):
        """Zapisuje klucz anonimizacji do katalogu /tmp"""
        # Generowanie unikalnej nazwy pliku z timestampem
        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        filename = f"anonymization_key_{ts}.json"
        
        # Używamy tempfile.gettempdir() dla kompatybilności (Linux: /tmp, Windows: Temp)
        tmp_dir = tempfile.gettempdir()
        mapping_path = os.path.join(tmp_dir, filename)
        
        with open(mapping_path, 'w', encoding='utf-8') as f:
            # Odwracamy słownik: ID -> Oryginał dla łatwego odczytu
            readable_mapping = {
                cat: {v: k for k, v in values.items()} 
                for cat, values in self.mappings.items()
            }
            json.dump(readable_mapping, f, indent=4)
        return mapping_path

    def process_file(self, in_p, out_p):
        _, ext = os.path.splitext(in_p)
        try:
            with open(in_p, 'r', encoding='utf-8', errors='ignore') as f:
                if ext.lower() == '.json':
                    data = json.load(f)
                    res = self._recursive_json(data)
                    with open(out_p, 'w', encoding='utf-8') as o:
                        json.dump(res, o, indent=4)
                else:
                    with open(out_p, 'w', encoding='utf-8') as o:
                        for line in f:
                            o.write(self.mask_text(line))
        except Exception as e:
            print(f"  [!] Błąd pliku {in_p}: {e}")

    def _recursive_json(self, data):
        if isinstance(data, dict): return {k: self._recursive_json(v) for k, v in data.items()}
        if isinstance(data, list): return [self._recursive_json(i) for i in data]
        if isinstance(data, str): return self.mask_text(data)
        return data

def main():
    if len(sys.argv) < 2:
        print("Użycie: python anonymizer_pro.py <katalog> [<fraza_w_nazwie_pliku>]")
        return

    input_dir = sys.argv[1].rstrip(os.sep)
    file_filter = sys.argv[2] if len(sys.argv) > 2 else None
    output_dir = f"{input_dir}_OUT"
    
    if not os.path.isdir(input_dir):
        print(f"Błąd: {input_dir} nie jest katalogiem.")
        return

    anonymizer = LogAnonymizer()
    print(f"[*] Rozpoczynam proces...")
    print(f"[*] Pliki wynikowe trafią do: {output_dir}")

    for root, _, files in os.walk(input_dir):
        for file_name in files:
            in_path = os.path.join(root, file_name)
            
            # Decyzja o anonimizacji nazwy pliku
            target_name = file_name
            if file_filter and file_filter in file_name:
                target_name = anonymizer.mask_text(file_name)
            
            rel_path = os.path.relpath(root, input_dir)
            out_path = os.path.join(output_dir, rel_path, target_name)
            
            os.makedirs(os.path.dirname(out_path), exist_ok=True)
            print(f"  -> Przetwarzam: {file_name}")
            anonymizer.process_file(in_path, out_path)

    # Zapisanie klucza w bezpiecznym miejscu (/tmp)
    key_file = anonymizer.save_mapping_to_tmp()
    
    print("-" * 40)
    print(f"[V] Anonimizacja zakończona sukcesem.")
    print(f"[!] KLUCZ DEKODUJĄCY: {key_file}")
    print(f"[i] Pamiętaj, aby zabezpieczyć ten plik!")

if __name__ == "__main__":
    main()