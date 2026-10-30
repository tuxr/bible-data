#!/usr/bin/env python3 -I
"""Seed the heb <-> eng versification mapping from bible-api's versification-map.json.

Usage: seed-heb-eng-mappings.py <bible-api-checkout> <out.json>

bible-api's entries are WLC <-> English (WEB/KJV agree everywhere in that corpus). Each entry
becomes one correspondence between the `heb` and `eng` schemes. Kinds are renamed to be
direction-neutral: wlc_extra -> sourceOnly, english_extra -> targetOnly.
"""
import json, subprocess, sys

KINDS = {
    "superscription_as_v1": "superscriptionAsVerse1",
    "chapter_boundary_split": "chapterBoundarySplit",
    "wlc_extra": "sourceOnly",
    "english_extra": "targetOnly",
}

def main(api_dir, out_path):
    src = json.load(open(f"{api_dir}/data/versification-map.json"))
    commit = subprocess.check_output(["git", "-C", api_dir, "rev-parse", "HEAD"], text=True).strip()
    entries = []
    for m in src["mappings"]:
        if m["kjv"] != m["english"]:
            sys.exit(f"WEB and KJV disagree at {m}; the eng scheme assumes one English numbering")
        e = {"book": m["book_id"], "kind": KINDS[m["kind"]]}
        if m["wlc"] is not None:
            e["source"] = [m["wlc"]["chapter"], m["wlc"]["verse"]]
        if m["english"] is not None:
            e["target"] = [m["english"]["chapter"], m["english"]["verse"]]
        entries.append(e)
    out = {
        "source": "heb",
        "target": "eng",
        "seededFrom": {"repo": "tuxr/bible-api", "commit": commit, "file": "data/versification-map.json",
                       "generatedAt": src["generated_at"]},
        "entries": entries,
    }
    with open(out_path, "w") as f:
        json.dump(out, f, indent=1, ensure_ascii=False)
        f.write("\n")
    kinds = {}
    for e in entries: kinds[e["kind"]] = kinds.get(e["kind"], 0) + 1
    print(len(entries), "entries", kinds)

if __name__ == "__main__":
    main(*sys.argv[1:3])
