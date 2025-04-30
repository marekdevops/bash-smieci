#!/usr/bin/env python3
import sys
import itertools

SROD = ['ts', 't1', 't2', 't3', 'dv', 'pp', 'sr']
TYP = ['ap', 'db', 'fl']
SYSOP = ['l', 'w', 'a', 'o']

def main():
    args = sys.argv[1:]

    if len(args) < 1:
        print("Użycie: ./skrypt.py NAZWA [SROD] [TYP] [SYSOP]")
        sys.exit(1)

    app = args[0]
    srod = [args[1]] if len(args) > 1 and args[1] in SROD else SROD
    typ = [args[2]] if len(args) > 2 and args[2] in TYP else ['ap']
    sysop = [args[3]] if len(args) > 3 and args[3] in SYSOP else ['l']

    for s, t, z in itertools.product(srod, typ, sysop):
        stala_czesc = f"{s}-{t}-{z}-"
        max_dlugosc_app = 12 - len(stala_czesc)
        app_part = app[:max_dlugosc_app].ljust(max_dlugosc_app, '_')
        nazwa = f"{stala_czesc}{app_part}"
        print(nazwa)

if __name__ == "__main__":
    main()
