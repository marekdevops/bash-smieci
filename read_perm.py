import os
import stat
import pwd
import grp

#!/usr/bin/env python3

def get_permissions(path):
    """Zwraca uprawnienia w formacie czytelnym dla człowieka"""
    try:
        file_stat = os.stat(path)
        mode = file_stat.st_mode
        
        # Konwersja uprawnień na format rwxrwxrwx
        perms = stat.filemode(mode)
        
        # Pobierz właściciela i grupę
        try:
            owner = pwd.getpwuid(file_stat.st_uid).pw_name
        except KeyError:
            owner = str(file_stat.st_uid)
            
        try:
            group = grp.getgrgid(file_stat.st_gid).gr_name
        except KeyError:
            group = str(file_stat.st_gid)
            
        return f"{perms} {owner}:{group} {path}"
    except (OSError, PermissionError) as e:
        return f"ERROR: {path} - {str(e)}"

def scan_directories_only(root_path="/", output_file="directories_permissions.txt"):
    """Skanuje tylko katalogi z katalogu głównego"""
    print(f"Skanowanie katalogów z {root_path}...")
    
    with open(output_file, 'w') as f:
        f.write(f"Uprawnienia katalogów z {root_path}\n")
        f.write("=" * 50 + "\n\n")
        
        try:
            for item in os.listdir(root_path):
                item_path = os.path.join(root_path, item)
                if os.path.isdir(item_path):
                    perm_info = get_permissions(item_path)
                    f.write(perm_info + "\n")
                    print(perm_info)
        except PermissionError as e:
            error_msg = f"ERROR: Brak uprawnień do odczytu {root_path}: {str(e)}"
            f.write(error_msg + "\n")
            print(error_msg)

def scan_important_directories(output_file="important_files_permissions.txt"):
    """Skanuje wszystkie pliki w ważnych katalogach"""
    important_dirs = ["/etc", "/home", "/lib", "/lib64", "/usr", "/var", "/tmp"]
    
    print("Skanowanie ważnych katalogów...")
    
    with open(output_file, 'w') as f:
        f.write("Uprawnienia plików w ważnych katalogach\n")
        f.write("=" * 50 + "\n\n")
        
        for directory in important_dirs:
            if not os.path.exists(directory):
                continue
                
            f.write(f"\n=== {directory} ===\n")
            print(f"Skanowanie {directory}...")
            
            try:
                for root, dirs, files in os.walk(directory):
                    # Zapisz uprawnienia katalogu
                    perm_info = get_permissions(root)
                    f.write(f"DIR:  {perm_info}\n")
                    
                    # Zapisz uprawnienia plików
                    for file in files:
                        file_path = os.path.join(root, file)
                        perm_info = get_permissions(file_path)
                        f.write(f"FILE: {perm_info}\n")
                        
            except PermissionError as e:
                error_msg = f"ERROR: Brak uprawnień do {directory}: {str(e)}"
                f.write(error_msg + "\n")
                print(error_msg)

def main():
    # Sprawdź czy skrypt jest uruchomiony z uprawnieniami roota
    if os.geteuid() != 0:
        print("UWAGA: Skrypt nie jest uruchomiony z uprawnieniami root.")
        print("Niektóre pliki mogą być niedostępne.")
        input("Naciśnij Enter aby kontynuować...")
    
    print("Rozpoczynam skanowanie systemu plików...")
    
    # Skanuj katalogi z /
    scan_directories_only("/", "directories_permissions.txt")
    print("Zapisano uprawnienia katalogów do: directories_permissions.txt")
    
    # Skanuj wszystkie pliki w ważnych katalogach
    scan_important_directories("important_files_permissions.txt")
    print("Zapisano uprawnienia plików do: important_files_permissions.txt")
    
    print("Skanowanie zakończone!")

if __name__ == "__main__":
    main()