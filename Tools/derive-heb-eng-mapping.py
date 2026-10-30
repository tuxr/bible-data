#!/usr/bin/env python3 -I
"""Derive the heb -> eng versification mapping from STEPBible's TVTMS.

Usage: derive-heb-eng-mapping.py <tvtms.txt> <heb.json> <eng.json> <out.json>

<tvtms.txt> is the pinned TVTMS file below. Its licence asks users to fetch it from
github.com/STEPBible rather than redistribute it, so it is an argument and not a repo file.
Only the condensed section's `English KJV` and `Hebrew` columns are read. Every verse the
entries leave unnamed keeps its number. The derived mapping is checked for completeness
against the verse counts before it is written.
"""
import hashlib, json, re, sys
from collections import Counter, defaultdict
from pathlib import Path

TVTMS = {
    "repo": "https://github.com/STEPBible/STEPBible-Data",
    "commit": "be4191f0082aeedddb0eff0c02c966292b2bd641",
    "file": "Versification/TVTMS - Translators Versification Traditions with Methodology for Standardisation"
            " for Eng+Heb+Lat+Grk+Others - STEPBible.org CC BY.txt",
    "sha256": "63058e0f20201af4bdaa7d830da5be8f493455d947c5f147d84840b33db9ddf8",
    "license": "CC BY 4.0",
    "attribution": "Versification data derived from TVTMS by STEPBible.org, Tyndale House Cambridge, CC BY 4.0",
}

ROW_KINDS = {
    "OneToOne", "SubdividedVerse", "MergedPrevVerse", "MergedFollVerse", "MergedVerse", "TextMayBeMissing",
    "DuplicateTarget", "StartDifferent", "PassageMissing", "PassageMoved", "Colophon", "LongVerse", "LongVerseElsewhere",
    "LongVerseElsewhereJoin", "LongVerse/LVElsewhere", "LongVerseDuplicated", "LongVerse/LVDuplicated",
    "LongVerse/LVExtra",
}

# English verses the condensed rows mark `Absent [=...]` in Hebrew on a row that does not merge them into
# that Hebrew verse. The expanded section is explicit: Hebrew Neh.7:68 is "IfEmpty verse", "Hebrew= --".
ABSENT_FROM_HEBREW = {("NEH", 7, 68)}

BOOK_SWIFT = Path(__file__).resolve().parent.parent / "Sources/BibleFormat/Book.swift"


def fail(message):
    sys.exit(f"derive-heb-eng-mapping: {message}")


def load_counts(path, scheme):
    data = json.load(open(path, encoding="utf-8"))
    if data["scheme"] != scheme:
        fail(f"{path} declares scheme {data['scheme']}, expected {scheme}")
    return {b["book"]: b["verses"] for b in data["books"]}


def verse_refs(counts, canon):
    return [(book, c + 1, v) for book in canon if book in counts
            for c, n in enumerate(counts[book]) for v in range(1, n + 1)]


def exists(counts, ref):
    book, chapter, verse = ref
    chapters = counts.get(book)
    return chapters is not None and 1 <= chapter <= len(chapters) and 1 <= verse <= chapters[chapter - 1]


class Cells:
    """Parses one TVTMS cell into a tagged value. Book codes are checked against `Book.allCases`."""

    def __init__(self, books):
        self.books = books

    def book(self, code, where):
        usfm = code.upper()
        if usfm not in self.books:
            fail(f"{where}: unknown book code {code!r}")
        return usfm

    def book_of(self, cell, where):
        m = re.match(r"([1-4A-Za-z][A-Za-z0-9]{2})\.", cell)
        if not m:
            fail(f"{where}: English cell {cell!r} names no book")
        return self.book(m.group(1), where)

    def parse(self, cell, where):
        if cell == "NoVerse":
            return ("none",)
        if cell == "Absent":
            return ("absent", [])
        m = re.fullmatch(r"Absent \[=(.+)\]", cell)
        if m:
            merged_into = self.refs(m.group(1), where)
            if merged_into is None:
                fail(f"{where}: Absent names a subverse")
            return ("absent", merged_into)
        m = re.fullmatch(r"([1-4A-Za-z][A-Za-z0-9]{2})\.(\d+):Title", cell)
        if m:
            return ("title", (self.book(m.group(1), where), int(m.group(2))))
        return ("refs", self.refs(cell, where))

    def refs(self, text, where):
        """`Gen.32:2-33`, `1Sa.20:42; 21:1`. Subverse `.0` is the verse itself; `.1` and up are not numbered."""
        m = re.fullmatch(r"([1-4A-Za-z][A-Za-z0-9]{2})\.(.+)", text)
        if not m:
            fail(f"{where}: cannot read reference {text!r}")
        book = self.book(m.group(1), where)
        out = []
        for item in m.group(2).split(";"):
            im = re.fullmatch(r"\s*(\d+):(\d+)(?:\.(\d+))?(?:-(\d+)(?:\.(\d+))?)?\s*", item)
            if not im:
                fail(f"{where}: cannot read reference {text!r}")
            chapter, first, sub1, last, sub2 = im.groups()
            if (sub1 not in (None, "0")) or (sub2 not in (None, "0")):
                return None
            first = int(first)
            last = int(last) if last else first
            if last < first:
                fail(f"{where}: descending range {text!r}")
            out += [(book, int(chapter), v) for v in range(first, last + 1)]
        return out


def read_rows(lines):
    """Yields (where, row kind, English cell, Hebrew cell) for every data row of a block with a Hebrew column."""
    start = next(i for i, l in enumerate(lines) if l.startswith("#DataStart(Condensed)"))
    end = next(i for i, l in enumerate(lines) if l.startswith("#DataEnd(Condensed)"))
    columns = None
    block = None
    for number, line in enumerate(lines[start + 1:end], start + 2):
        row = [c.strip() for c in line.rstrip("\r").split("\t")]
        first = row[0]
        if first.lstrip("#").startswith("$"):
            block = first
            headers = {h: i for i, h in enumerate(row) if h and i > 0}
            columns = None if first.startswith("#") else headers or None
            continue
        if first == "BIBLES":
            columns = {h: i for i, h in enumerate(row) if h and i > 0}
            continue
        if columns is None or "Hebrew" not in columns:
            continue
        if not first or first.startswith(("#", "'", ",")) or "TEST" in first:
            continue
        where = f"line {number} ({block})"
        if first not in ROW_KINDS:
            fail(f"{where}: unknown row kind {first!r}")
        if "English KJV" not in columns:
            fail(f"{where}: block has a Hebrew column but no English KJV column")
        cell = lambda name: row[columns[name]] if columns[name] < len(row) else ""
        yield where, first, cell("English KJV"), cell("Hebrew")


class Correspondence:
    """The relation between Hebrew and English verses that the rows state, before kinds are assigned."""

    def __init__(self, heb, eng):
        self.heb, self.eng = heb, eng
        self.edges = set()
        self.titles = set()
        self.english_only = set()

    def add(self, where, kind, english, hebrew):
        if english == hebrew:
            if english[0] == "refs" and english[1] is not None:
                for ref in english[1]:
                    self.link(where, ref, ref)
            return
        etag, htag = english[0], hebrew[0]
        if etag == "refs" and english[1] is None:
            if htag == "none":
                return
            fail(f"{where}: English names a subverse against a Hebrew verse")
        if htag == "none":
            fail(f"{where}: Hebrew has no verse against an English verse")
        if etag == "title":
            book, chapter = english[1]
            if htag == "refs":
                for ref in hebrew[1]:
                    if (ref[0], ref[1]) != (book, chapter):
                        fail(f"{where}: title row names a verse outside its psalm")
                    self.titles.add(self.checked(where, ref, self.heb, "heb"))
                return
            if htag == "absent" and hebrew[1] == [(book, chapter, 1)]:
                return
            fail(f"{where}: unexpected Hebrew {hebrew} against an English title")
        if etag != "refs":
            fail(f"{where}: unexpected English cell {english}")
        eng_refs = english[1]
        if htag == "absent":
            if kind == "MergedPrevVerse" and len(hebrew[1]) == 1:
                for ref in eng_refs:
                    self.link(where, hebrew[1][0], ref)
                return
            if all(ref in ABSENT_FROM_HEBREW for ref in eng_refs):
                self.english_only.update(self.checked(where, ref, self.eng, "eng") for ref in eng_refs)
                return
            fail(f"{where}: {kind} row marks English {eng_refs} absent in Hebrew; read it and extend the tool")
        heb_refs = hebrew[1]
        if heb_refs is None:
            fail(f"{where}: Hebrew names a subverse")
        if len(heb_refs) == len(eng_refs):
            pairs = zip(heb_refs, eng_refs)
        elif len(heb_refs) == 1 or len(eng_refs) == 1:
            pairs = [(h, e) for h in heb_refs for e in eng_refs]
        else:
            fail(f"{where}: {len(heb_refs)} Hebrew verses against {len(eng_refs)} English verses")
        for h, e in pairs:
            self.link(where, h, e)

    def checked(self, where, ref, counts, scheme):
        if not exists(counts, ref):
            fail(f"{where}: {ref} is not a verse of {scheme}")
        return ref

    def link(self, where, h, e):
        self.edges.add((self.checked(where, h, self.heb, "heb"), self.checked(where, e, self.eng, "eng")))


def entries_from(relation):
    """Groups the edges into connected components and gives each component its kind."""
    parent = {}

    def find(node):
        parent.setdefault(node, node)
        while parent[node] != node:
            parent[node] = parent[parent[node]]
            node = parent[node]
        return node

    for h, e in relation.edges:
        parent[find(("h", h))] = find(("e", e))
    components = defaultdict(list)
    for h, e in relation.edges:
        components[find(("h", h))].append((h, e))

    entries = []
    for edges in components.values():
        hebs = {h for h, _ in edges}
        engs = {e for _, e in edges}
        if len(hebs) > 1 and len(engs) > 1:
            fail(f"{sorted(hebs)} and {sorted(engs)} form a many-to-many group")
        if len(hebs) == 1 and len(engs) == 1:
            ((h, e),) = edges
            if h != e:
                entries.append({"book": h[0], "kind": "renumbered", "source": h, "target": e})
            continue
        entries += [{"book": h[0], "kind": "splitVerse", "source": h, "target": e} for h, e in edges]

    linked_heb = {h for h, _ in relation.edges}
    linked_eng = {e for _, e in relation.edges}
    for ref in relation.titles:
        if ref in linked_heb:
            fail(f"heb {ref} is both a title and a numbered verse")
        entries.append({"book": ref[0], "kind": "superscriptionAsVerse1", "source": ref})
    for ref in relation.english_only:
        if ref in linked_eng:
            fail(f"eng {ref} is both absent and linked")
        entries.append({"book": ref[0], "kind": "extraVerse", "target": ref})
    return entries


def check(entries, heb, eng, canon):
    """Rebuilds heb -> eng from the entries alone, identity as default, and proves it complete."""
    forward = defaultdict(set)
    heb_only, eng_only = set(), set()
    named_heb, named_eng = set(), set()
    for e in entries:
        source, target = e.get("source"), e.get("target")
        if source:
            named_heb.add(source)
        if target:
            named_eng.add(target)
        if source and target:
            forward[source].add((target, e["kind"]))
        elif source:
            heb_only.add(source)
        else:
            eng_only.add(target)

    reached = defaultdict(list)
    for ref in verse_refs(heb, canon):
        if ref in forward:
            targets = forward[ref]
        elif ref in heb_only:
            continue
        else:
            if not exists(eng, ref):
                fail(f"(a) heb {ref} keeps its number, which eng lacks")
            if ref in named_eng:
                fail(f"(a) heb {ref} keeps its number, but an entry already names eng {ref}")
            targets = {(ref, None)}
        for target, kind in targets:
            reached[target].append((ref, kind))

    for ref in verse_refs(eng, canon):
        if ref[0] not in heb:
            continue
        sources = reached.get(ref, [])
        if ref in eng_only:
            if sources:
                fail(f"(b) eng {ref} is marked absent but heb {sources} reach it")
            continue
        if not sources:
            fail(f"(b) eng {ref} is reached by no heb verse")
        if len(sources) > 1 and any(kind != "splitVerse" for _, kind in sources):
            fail(f"(c) eng {ref} is reached by {sources} outside a split")

    net = Counter()
    for ref in heb_only:
        net[ref[0]] += 1
    for ref in eng_only:
        net[ref[0]] -= 1
    split_heb, split_eng = defaultdict(set), defaultdict(set)
    for e in entries:
        if e["kind"] == "splitVerse":
            split_heb[e["book"]].add(e["source"])
            split_eng[e["book"]].add(e["target"])
    for book in split_heb:
        net[book] += len(split_heb[book]) - len(split_eng[book])
    for book in canon:
        if book not in heb:
            continue
        expected = sum(heb[book]) - sum(eng[book])
        if net[book] != expected:
            fail(f"(d) {book}: entries give a net of {net[book]:+}, counts give {expected:+}")
    return net


def summarize(entries, net, canon):
    kinds = Counter(e["kind"] for e in entries)
    print(f"{len(entries)} entries")
    for kind in sorted(kinds):
        print(f"  {kind:24}{kinds[kind]:6}")
    columns = ["renumbered", "superscriptionAsVerse1", "splitVerse", "extraVerse"]
    per_book = defaultdict(Counter)
    for e in entries:
        per_book[e["book"]][e["kind"]] += 1
    print(f"\n{'book':6}{'renumbered':>12}{'superscr.':>11}{'split':>7}{'extra':>7}{'net':>6}")
    for book in canon:
        if book in per_book:
            c = per_book[book]
            print(f"{book:6}" + "".join(f"{c[k]:>{w}}" for k, w in zip(columns, (12, 11, 7, 7))) + f"{net[book]:>+6}")


def write(entries, out_path, canon):
    order = {book: i for i, book in enumerate(canon)}

    def key(e):
        side = e.get("source") or e.get("target")
        return (order[e["book"]], side[1:], 0 if "source" in e else 1, (e.get("target") or ())[1:])

    lines = []
    for e in sorted(entries, key=key):
        fields = [f'"book": "{e["book"]}"', f'"kind": "{e["kind"]}"']
        for side in ("source", "target"):
            if side in e:
                fields.append(f'"{side}": [{e[side][1]}, {e[side][2]}]')
        lines.append("  {" + ", ".join(fields) + "}")
    header = {"source": "heb", "target": "eng", "seededFrom": TVTMS}
    head = json.dumps(header, indent=1, ensure_ascii=False)[:-2]
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(head + ',\n "entries": [\n' + ",\n".join(lines) + "\n ]\n}\n")


def main(tvtms_path, heb_path, eng_path, out_path):
    raw = open(tvtms_path, "rb").read()
    sha = hashlib.sha256(raw).hexdigest()
    if sha != TVTMS["sha256"]:
        fail(f"{tvtms_path} has sha256 {sha}, expected the pinned {TVTMS['sha256']}")
    canon = re.findall(r'case \w+ = "(\w+)"', BOOK_SWIFT.read_text(encoding="utf-8"))
    heb, eng = load_counts(heb_path, "heb"), load_counts(eng_path, "eng")
    cells = Cells(set(canon))
    relation = Correspondence(heb, eng)
    for where, kind, english, hebrew in read_rows(raw.decode("utf-8-sig").split("\n")):
        if cells.book_of(english, where) not in heb:
            continue
        relation.add(where, kind, cells.parse(english, where), cells.parse(hebrew, where))
    entries = entries_from(relation)
    net = check(entries, heb, eng, canon)
    write(entries, out_path, canon)
    summarize(entries, net, canon)


if __name__ == "__main__":
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    main(*sys.argv[1:])
