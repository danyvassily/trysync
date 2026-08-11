#!/usr/bin/env python3
"""Applique les patchs old_string → new_string d'un rapport d'agent (Markdown).
Usage : python3 apply_patches.py <rapport.md> <fichier_source.swift> [--dry-run]
"""
import re
import sys

def parse_patches(md_path):
    text = open(md_path, encoding='utf-8').read()
    patches = []
    parts = text.split('**old_string**')
    for part in parts[1:]:
        m_old = re.search(r'```(?:swift)?\s*\n(.*?)```', part, re.DOTALL)
        if not m_old:
            continue
        old = m_old.group(1)
        rest = part[m_old.end():]
        m_new = re.search(r'```(?:swift)?\s*\n(.*?)```', rest, re.DOTALL)
        if not m_new:
            print(f"  !!! old sans new (début: {old[:60]!r})")
            continue
        new = m_new.group(1)
        patches.append((old, new))
    return patches

def main():
    md_path, src_path = sys.argv[1], sys.argv[2]
    dry = '--dry-run' in sys.argv
    patches = parse_patches(md_path)
    print(f"Rapport : {md_path} — {len(patches)} patchs parsés")
    src = open(src_path, encoding='utf-8').read()
    ok, fail, ambig = 0, 0, 0
    for i, (old, new) in enumerate(patches, 1):
        count = src.count(old)
        if count == 0:
            fail += 1
            print(f"  ✗ Patch {i}: INTROUVABLE — {old[:70]!r}")
            continue
        if count > 1:
            ambig += 1
            print(f"  ⚠ Patch {i}: AMBIGU ({count} occurrences) — {old[:70]!r}")
            continue
        src = src.replace(old, new, 1)
        ok += 1
    if not dry:
        open(src_path, 'w', encoding='utf-8').write(src)
    print(f"Résultat : {ok} OK / {fail} introuvables / {ambig} ambigus")
    print(f"Fichier : {len(src.splitlines())} lignes ({'DRY-RUN' if dry else 'ÉCRIT'})")
    return 1 if fail or ambig else 0

if __name__ == '__main__':
    sys.exit(main())
