#!/usr/bin/env python3
import sys
import itertools

# Listy możliwych wartości
XX_list = ['pr', 'ts', 't1', 't2', 't3', 'dv', 'pp', 'sr']
YY_list = ['ap', 'db', 'fl']
Z_list = ['l', 'w', 'a', 'o']

def main():
    if len(sys.argv) != 2:
        print("Użycie: ./skrypt-nazwa.py NAZWA")
        sys.exit(1)

    user_input = sys.argv[1]

    # Długość prefiksu: XX-YY-Z- = 2+1+2+1+1+1 = 8 znaków
    prefix_length = len("XX-YY-Z-")
    max_suffix_length = 12 - prefix_length

    # Skracanie lub dopełnianie nazw własnych
    if len(user_input) > max_suffix_length:
        suffix = user_input[:max_suffix_length]
    else:
        suffix = user_input.ljust(max_suffix_length, '_')  # np. dopełnienie "_"

    # Tworzenie i wypisywanie wszystkich kombinacji
    for xx, yy, z in itertools.product(XX_list, YY_list, Z_list):
        name = f"{xx}-{yy}-{z}-{suffix}"
        print(name)

if __name__ == "__main__":
    main()
