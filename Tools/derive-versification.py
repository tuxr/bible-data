#!/usr/bin/env python3 -I
"""Derive per-chapter verse counts for one versification scheme from a USFX zip.

Usage: derive-versification.py <scheme> <zip> <source-sha256> <out.json>

The count for a chapter is the highest integer verse number marked in it. Verse ids
such as "1-2" or "12a" contribute their leading integer. Books outside the 66-book
canon (front matter, glossaries) are skipped.
"""
import json, re, sys, zipfile, hashlib

CANON = ["GEN","EXO","LEV","NUM","DEU","JOS","JDG","RUT","1SA","2SA","1KI","2KI","1CH","2CH","EZR","NEH","EST","JOB","PSA","PRO","ECC","SNG","ISA","JER","LAM","EZK","DAN","HOS","JOL","AMO","OBA","JON","MIC","NAM","HAB","ZEP","HAG","ZEC","MAL","MAT","MRK","LUK","JHN","ACT","ROM","1CO","2CO","GAL","EPH","PHP","COL","1TH","2TH","1TI","2TI","TIT","PHM","HEB","JAS","1PE","2PE","1JN","2JN","3JN","JUD","REV"]

def main(scheme, zip_path, expected_sha, out_path):
    raw = open(zip_path, "rb").read()
    sha = hashlib.sha256(raw).hexdigest()
    if sha != expected_sha:
        sys.exit(f"sha256 mismatch: {sha} != {expected_sha}")
    z = zipfile.ZipFile(zip_path)
    usfx = [n for n in z.namelist() if n.endswith("_usfx.xml")][0]
    xml = z.read(usfx).decode("utf-8")
    counts = {}
    book = chapter = None
    for m in re.finditer(r'<(book|c|v)\b([^>]*)>', xml):
        tag, attrs = m.group(1), m.group(2)
        idm = re.search(r'\bid="([^"]*)"', attrs)
        if not idm:
            continue
        ident = idm.group(1)
        if tag == "book":
            book = ident if ident in CANON else None
            chapter = None
        elif tag == "c" and book:
            chapter = int(ident)
            counts.setdefault(book, {}).setdefault(chapter, 0)
        elif tag == "v" and book and chapter is not None:
            lead = re.match(r'\d+', ident)
            if lead:
                n = int(lead.group(0))
                if n > counts[book][chapter]:
                    counts[book][chapter] = n
    books = []
    for b in CANON:
        if b not in counts:
            continue
        chapters = counts[b]
        books.append({"book": b, "verses": [chapters[c] for c in sorted(chapters)]})
    out = {
        "scheme": scheme,
        "derivedFrom": {"file": usfx, "zip": zip_path.split("/")[-1], "zipSha256": sha},
        "books": books,
    }
    with open(out_path, "w") as f:
        json.dump(out, f, indent=1, ensure_ascii=False)
        f.write("\n")
    total = sum(sum(b["verses"]) for b in books)
    print(f"{scheme}: {len(books)} books, {sum(len(b['verses']) for b in books)} chapters, {total} verses -> {out_path}")

if __name__ == "__main__":
    main(*sys.argv[1:5])
