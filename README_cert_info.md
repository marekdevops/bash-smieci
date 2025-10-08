# Skrypt do analizy certyfikatów - cert_info.sh

## Opis
Skrypt w bash-u dostosowany do systemów Red Hat (RHEL/CentOS/Fedora), który wyciąga certyfikaty z bundla i wyświetla szczegółowe informacje o nich w przyjazny sposób.

## Wymagania systemowe
- Red Hat Enterprise Linux / CentOS / Fedora
- openssl (zainstalowany domyślnie lub przez `yum install openssl` / `dnf install openssl`)
- bash 4.0+

## Użycie

### Składnia
```bash
./cert_info.sh [OPCJE] NAZWA_CERTYFIKATU PLIK_BUNDLA
```

### Parametry
- `NAZWA_CERTYFIKATU` - Nazwa certyfikatu do wyszukania (np. example.com, google.com)
- `PLIK_BUNDLA` - Ścieżka do pliku z bundlem certyfikatów (format PEM)

### Opcje
- `-h, --help` - Wyświetl pomoc
- `-v, --verbose` - Tryb szczegółowy (dodatkowe informacje techniczne)
- `-d, --days LICZBA` - Sprawdź certyfikaty wygasające w ciągu podanych dni (domyślnie: 30)

## Przykłady użycia

### Podstawowe użycie
```bash
# Wyszukanie certyfikatów dla google.com
./cert_info.sh google.com /etc/ssl/certs/ca-bundle.crt

# Wyszukanie certyfikatów w lokalnym pliku
./cert_info.sh example.com ./certificates.pem
```

### Z opcjami
```bash
# Tryb szczegółowy
./cert_info.sh -v mysite.com /path/to/bundle.pem

# Sprawdzenie certyfikatów wygasających w ciągu 60 dni
./cert_info.sh -d 60 example.com /etc/ssl/certs/ca-bundle.crt

# Kombinacja opcji
./cert_info.sh -v -d 90 secure.example.com ./ssl-bundle.pem
```

## Funkcjonalności

### Wyświetlane informacje
- 👤 Właściciel certyfikatu (Subject)
- 🏢 Wystawca certyfikatu (Issuer)  
- 🔢 Numer seryjny
- 📅 Daty ważności (od/do) w czytelnym formacie
- ⚠️ Status certyfikatu (ważny/wygasający/wygasły)
- 🌐 Alternatywne nazwy domen (SAN)
- 🔑 Sposób użycia klucza

### W trybie szczegółowym (-v)
- 🔐 Algorytm podpisu
- 🔢 Rozmiar klucza (w bitach)
- 👆 SHA256 Fingerprint

### Kolorowe oznaczenia statusu
- ✅ **Zielony**: Certyfikat ważny
- ⚠️ **Żółty**: Certyfikat wygasa wkrótce
- ❌ **Czerwony**: Certyfikat wygasły

## Typowe lokalizacje bundli na Red Hat
```bash
# System CA bundle
/etc/ssl/certs/ca-bundle.crt
/etc/pki/tls/certs/ca-bundle.crt

# Dodatkowe certyfikaty
/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem
/etc/ssl/certs/
```

## Przykładowe wyjście
```
===============================================
🔍 Wyszukiwanie certyfikatów dla: google.com
===============================================
📁 Plik bundla: /etc/ssl/certs/ca-bundle.crt
📅 Data sprawdzenia: 2025-10-08 14:30:15

🔎 Przeszukiwanie bundla...

🎯 ZNALEZIONY CERTYFIKAT #1
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
👤 Właściciel: CN=*.google.com,O=Google LLC,L=Mountain View,ST=California,C=US
🏢 Wystawca: CN=GTS CA 1C3,O=Google Trust Services LLC,C=US
🔢 Numer seryjny: 0A:1B:2C:3D:4E:5F
📅 Ważny od: 2025-09-01 10:30:45 (niedziela)
📅 Ważny do: 2025-11-30 10:30:45 (niedziela)
✅ STATUS: WAŻNY (wygasa za 53 dni)
🌐 Alternatywne nazwy:
   • *.google.com
   • google.com
   • *.googleapis.com
🔑 Użycie klucza: Digital Signature, Key Encipherment
```

## Obsługa błędów
Skrypt sprawdza:
- Obecność narzędzia openssl
- Istnienie pliku bundla
- Uprawnienia do odczytu pliku
- Poprawność parametrów wejściowych

## Uwagi dla systemów Red Hat
- Skrypt używa standardowych narzędzi dostępnych w dystrybucjach Red Hat
- Kompatybilny z RHEL 7, 8, 9, CentOS oraz Fedora
- Używa `yum` lub `dnf` w instrukcjach instalacji w zależności od wersji systemu