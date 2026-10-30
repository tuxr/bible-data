# bible-data format

Format version 1 (unreleased)

This document defines the files that `bible-pack` writes and the app reads. The `BibleFormat` Swift module implements every rule here. `bible-pack` and the app's `BibleKit` both link `BibleFormat`, so the writer and the reader share one implementation.

## Scope and principles

The format has two kinds of file.

- An **edition package** holds one edition of scripture, such as the BSB or the WLC. It is a read-only SQLite 3 database.
- The **canon package**, `canon.sqlite`, holds the book table, the versification schemes, and the mappings between schemes. The app bundles it.

These rules hold for every file.

- A package is immutable. A new build of an edition is a new file with a new version. Nothing edits a released package.
- A package carries one edition. Adding an edition never changes another edition's file.
- Book ids are USFM 3-letter codes, such as `GEN`, `1SA`, and `REV`.
- Anchors that outlive a package, such as marks, notes, and reading positions, use the `eng` scheme. An edition in another scheme reaches `eng` through a mapping.
- Packages carry only the 66 books of the Protestant canon. The canon defines 86 books, so the Apocrypha can ship later without a format change.

## File names

An edition package is named `<id>-<yyyy.mm>.bible`.

- `<id>` is the edition id, a lowercase short code such as `bsb`, `wlc`, or `tcgnt`.
- `<yyyy.mm>` is the package version, the year and month of the build.

The canon package is named `canon.sqlite`.

## Edition package

### Tables

| Table | Rows | Purpose |
|---|---|---|
| `meta` | One per key | Format version and build provenance. Its shape never changes. |
| `edition` | Exactly one | What the edition is, where it came from, and how it is encoded. |
| `books` | One per book present | The books as this edition names them. |
| `chapters` | One per chapter | The encoded chapter content. |
| `verses` | One per verse | Plain text for search results, copy, and anchoring. |
| `verses_fts` | One per verse | The FTS5 search index over `verses.text_plain`. |
| `notes` | One per note | Footnotes, cross-references, and translator notes. |

### `meta`

`meta` is a key and value table. A reader reads `meta` before any other table, because its shape is the same in every format version.

| Key | Value |
|---|---|
| `format_version` | The format version as a decimal integer. The schema inserts it. |
| `format_minor` | The additive revision within the format version. The schema inserts it. |
| `built_at` | The build time, ISO 8601 in UTC. |
| `builder_version` | The `bible-pack` version that wrote the file. |
| `source_lock` | The `sources.lock.json` entry for the edition's source, as JSON. |

### `edition`

| Column | Meaning |
|---|---|
| `id` | The edition id, as in the file name. |
| `name` | The full name in the edition's own language. |
| `abbreviation` | The short display name, such as `BSB`. |
| `language` | A BCP 47 language tag, such as `en`, `hbo`, or `grc`. |
| `script` | An ISO 15924 script code, such as `Latn`, `Hebr`, or `Grek`. |
| `direction` | `ltr` or `rtl`. |
| `versification` | The scheme id the edition numbers its verses in. See Versification. |
| `license` | The license name, such as `Public domain` or `CC BY-SA 4.0`. |
| `attribution` | The attribution text the app shows in About and the word panel. |
| `publisher` | The publisher's name. |
| `source_url` | Where the source was downloaded from. |
| `source_revision` | The publisher's revision of the source. |
| `source_sha256` | The SHA-256 of the source file, lowercase hex. |
| `format_version` | Equal to `meta.format_version`. |
| `chapter_encoding` | The encoding id of every `chapters.content` blob. See Chapter encoding. |
| `built_at` | Equal to `meta.built_at`. |
| `canon` | The book ids present, in canonical order, separated by single spaces. |

### `books`

| Column | Meaning |
|---|---|
| `id` | The USFM book id. |
| `canon_order` | The book's canonical order, 1 to 86, from the canon. |
| `name` | The book's name in this edition. WLC names its books in Hebrew. |
| `short_name` | The edition's abbreviation for the book. |
| `chapters` | The number of chapters in this edition. |

The canon's order column is named `canon_order` because `order` is a reserved word in SQL.

### `chapters`

| Column | Meaning |
|---|---|
| `book` | The USFM book id. |
| `chapter` | The chapter number, 1 to 999. |
| `content` | The chapter, encoded with `edition.chapter_encoding`. |

### `verses`

| Column | Meaning |
|---|---|
| `id` | The verse row id. See Verse row ids. |
| `book` | The USFM book id. |
| `chapter` | The chapter number, 1 to 999. |
| `verse` | The verse number, 1 to 999. |
| `text_plain` | The verse text with no markup, notes, or verse numbers. |

Book, chapter, and verse use the edition's own versification.

### `notes`

| Column | Meaning |
|---|---|
| `book` | The USFM book id. |
| `chapter` | The chapter that holds the note caller. |
| `verse` | The verse that holds the note caller. `0` means before verse 1, as in a heading or a title. |
| `number` | The note's position in the chapter, from 1, in reading order. |
| `kind` | `footnote`, `crossReference`, or `translatorNote`. |
| `caller` | The caller glyph the edition prints, such as `a` or `*`. |
| `text` | The note text with no markup. |
| `targets` | The verses a cross-reference points at, or `NULL`. |

`targets` is a JSON array of ranges in the edition's versification. Each range has a `start` and an `end`, and each of those has a `book`, a `chapter`, and a `verse`. `NoteTargets.encode` writes it with sorted keys. `NoteTargets.decode` reads it.

```json
[{"end":{"book":"GEN","chapter":1,"verse":3},"start":{"book":"GEN","chapter":1,"verse":1}}]
```

### Verse row ids

A verse's row id is `canon_order × 1,000,000 + chapter × 1,000 + verse`. Genesis 1:1 is `1001001`. Revelation 22:21 is `66022021`.

- Every chapter and every verse number is below 1000 in every scheme, so the three parts never overlap. The longest chapter is Psalm 119 with 176 verses. The book with the most chapters is Psalms with 150.
- Row ids sort in canonical order. A book, a chapter, or a testament is one contiguous range of ids.
- The id is an explicit `INTEGER PRIMARY KEY`. `VACUUM` can renumber an implicit rowid, which would break the search index.
- A `CHECK` constraint rejects a row whose id disagrees with its chapter and verse.

`PackageSchema.verseRowID` computes the id. `PackageSchema.verseRef(rowID:)` inverts it.

### Search

`verses_fts` is an FTS5 table with external content. It indexes `verses.text_plain` and stores no second copy of the text. Its rowid is the verse row id, so results arrive in canonical order.

- The tokenizer is `unicode61 remove_diacritics 2`. It folds case and Latin diacritics, so `created` finds `créated`.
- Three triggers keep the index in step with `verses` on insert, delete, and update.
- The tokenizer does not fold Hebrew points or polytonic Greek accents and breathings. In SQLite 3.54, the query `בראשית` does not find `בְּרֵאשִׁית`, and `αρχη` does not find `ἀρχῇ`.

### Schema

`PackageSchema.ddl` holds the schema. A test checks that this block matches it.

```sql
CREATE TABLE meta (
  key TEXT PRIMARY KEY NOT NULL,
  value TEXT NOT NULL
) WITHOUT ROWID;

INSERT INTO meta (key, value) VALUES ('format_version', '1');
INSERT INTO meta (key, value) VALUES ('format_minor', '0');

CREATE TABLE edition (
  id TEXT PRIMARY KEY NOT NULL,
  name TEXT NOT NULL,
  abbreviation TEXT NOT NULL,
  language TEXT NOT NULL,
  script TEXT NOT NULL,
  direction TEXT NOT NULL CHECK (direction IN ('ltr', 'rtl')),
  versification TEXT NOT NULL CHECK (versification IN ('eng', 'heb', 'grc')),
  license TEXT NOT NULL,
  attribution TEXT NOT NULL,
  publisher TEXT NOT NULL,
  source_url TEXT NOT NULL,
  source_revision TEXT NOT NULL,
  source_sha256 TEXT NOT NULL,
  format_version INTEGER NOT NULL,
  chapter_encoding INTEGER NOT NULL,
  built_at TEXT NOT NULL,
  canon TEXT NOT NULL
);

CREATE TRIGGER edition_one_row BEFORE INSERT ON edition
WHEN (SELECT count(*) FROM edition) > 0
BEGIN
  SELECT RAISE(ABORT, 'edition holds one row');
END;

CREATE TABLE books (
  id TEXT PRIMARY KEY NOT NULL,
  canon_order INTEGER NOT NULL UNIQUE,
  name TEXT NOT NULL,
  short_name TEXT NOT NULL,
  chapters INTEGER NOT NULL CHECK (chapters BETWEEN 1 AND 999)
);

CREATE TABLE chapters (
  book TEXT NOT NULL REFERENCES books (id),
  chapter INTEGER NOT NULL CHECK (chapter BETWEEN 1 AND 999),
  content BLOB NOT NULL,
  PRIMARY KEY (book, chapter)
);

CREATE TABLE verses (
  id INTEGER PRIMARY KEY,
  book TEXT NOT NULL REFERENCES books (id),
  chapter INTEGER NOT NULL CHECK (chapter BETWEEN 1 AND 999),
  verse INTEGER NOT NULL CHECK (verse BETWEEN 1 AND 999),
  text_plain TEXT NOT NULL,
  UNIQUE (book, chapter, verse),
  CHECK (id % 1000 = verse AND id / 1000 % 1000 = chapter)
);

CREATE VIRTUAL TABLE verses_fts USING fts5 (
  text_plain,
  content = 'verses',
  content_rowid = 'id',
  tokenize = 'unicode61 remove_diacritics 2'
);

CREATE TRIGGER verses_fts_insert AFTER INSERT ON verses BEGIN
  INSERT INTO verses_fts (rowid, text_plain) VALUES (new.id, new.text_plain);
END;

CREATE TRIGGER verses_fts_delete AFTER DELETE ON verses BEGIN
  INSERT INTO verses_fts (verses_fts, rowid, text_plain) VALUES ('delete', old.id, old.text_plain);
END;

CREATE TRIGGER verses_fts_update AFTER UPDATE ON verses BEGIN
  INSERT INTO verses_fts (verses_fts, rowid, text_plain) VALUES ('delete', old.id, old.text_plain);
  INSERT INTO verses_fts (rowid, text_plain) VALUES (new.id, new.text_plain);
END;

CREATE TABLE notes (
  book TEXT NOT NULL REFERENCES books (id),
  chapter INTEGER NOT NULL CHECK (chapter BETWEEN 1 AND 999),
  verse INTEGER NOT NULL CHECK (verse BETWEEN 0 AND 999),
  number INTEGER NOT NULL CHECK (number >= 1),
  kind TEXT NOT NULL CHECK (kind IN ('footnote', 'crossReference', 'translatorNote')),
  caller TEXT NOT NULL,
  text TEXT NOT NULL,
  targets TEXT,
  PRIMARY KEY (book, chapter, number)
);
```

## Chapter content

### The model

A chapter is a flat stream of items in reading order. `Chapter` holds the book, the chapter number, and the items. Only the items are encoded. The book and chapter number come from the `chapters` row.

| Item | Meaning |
|---|---|
| `block(BlockKind)` | Starts a block. Text that follows belongs to it until the next block or heading. |
| `heading(level:, [Run])` | A section heading, level 1 to 3. It is its own block. |
| `title([Run])` | A Psalm superscription that the edition does not number as a verse. It is its own block. |
| `speaker([Run])` | A speaker label, as in the Song of Songs. It is its own block. |
| `verse(VerseLabel)` | Starts a verse. Text that follows belongs to it until the next verse marker. |
| `text(Run)` | A run of text in the current block and verse. |
| `noteCaller(NoteCaller)` | A note caller at this point in the text. |

The stream follows these rules.

- A `text` item comes after a `block` item. A heading, title, or speaker closes the current block, so text after one needs a new `block` item.
- A block can start in the middle of a verse. A verse can start in the middle of a block.
- Text before the first `verse` item belongs to no verse.

| Block kind | Meaning |
|---|---|
| `paragraph` | A normal paragraph with a first-line indent. |
| `flush` | A paragraph with no indent. |
| `indented` | An indented paragraph. |
| `poetry(level:)` | A poetry line, level 1 to 3. |
| `rightAligned` | A right-aligned line. |
| `centered` | A centered line. |
| `list(level:)` | A list item, level 1 to 3. |
| `blankLine` | Vertical space with no text. |

A `VerseLabel` holds the verse `number` and an optional `through` for a bridge. The label `1-2` is `number` 1 and `through` 2.

A `NoteCaller` holds the note's `number` in the `notes` table, its `kind`, and its caller `glyph`. The reader draws the caller without a query.

### Runs

A `Run` holds `text`, a `style`, and an optional `word`.

`style` is a `RunStyle` bit set, stored as a 16-bit unsigned integer. Bits 6 to 15 are reserved. A reader ignores bits it does not know.

| Bit | Flag | Meaning |
|---|---|---|
| 0 | `wordsOfJesus` | Words of Jesus, shown in red when red letter is on. |
| 1 | `addedWords` | Words the translators supplied, shown in italics. |
| 2 | `divineName` | The divine name, shown in small capitals. |
| 3 | `transliteration` | A transliterated word. |
| 4 | `quotedScripture` | Scripture quoted inside scripture. |
| 5 | `selah` | A liturgical marker such as "Selah". |

`word` is the 1-based position of the word in its verse, for word-tagged editions. It is `nil` for untagged editions and for spaces and punctuation. A word split across two styles has one `word` value on both runs. The `<edition>.words` companion package keys its tags by the same verse and position, so marks and word study share one coordinate system.

### Chapter encoding

`edition.chapter_encoding` names the encoding of every blob in `chapters.content`. One package has one encoding, so a reader picks the codec once when it opens the package. A reader refuses a package whose encoding it does not know.

| Id | Encoding | Use |
|---|---|---|
| 0 | `json` | Reference only. Swift's synthesized `Codable` output for `[ChapterItem]`, with sorted keys. Tests and the benchmark use it. No released package uses it. |
| 1 to 255 | Reserved | For the shipped encoding. |

The Phase 0 step 4 benchmark picks the shipped encoding. No package is released before then.

Every encoding meets two rules. Decoding an encoded chapter gives an equal `Chapter`. Encoding the same chapter twice gives the same bytes.

## Versification

### Schemes

| Id | Scheme | Counts derived from |
|---|---|---|
| `eng` | English, KJV tradition | KJV |
| `heb` | Masoretic | WLC |
| `grc` | Greek New Testament | TCGNT |

`lxx` is reserved for the Septuagint. `eng` is the canonical scheme for anchors.

### Verse count files

`Sources/BibleFormat/Resources/versification/<scheme>.json` holds the verse count of every chapter in the scheme.

```json
{"scheme": "eng", "derivedFrom": {"file": "...", "zip": "...", "zipSha256": "..."},
 "books": [{"book": "GEN", "verses": [31, 25, 24]}]}
```

- `books` lists each book once, in canonical order.
- `verses[n]` is the verse count of chapter `n + 1`.
- Every count is from 1 to 999.

| Scheme | Books | Chapters | Verses |
|---|---|---|---|
| `eng` | 66 | 1189 | 31102 |
| `heb` | 39 | 929 | 23213 |
| `grc` | 27 | 260 | 7958 |

### Mapping files

`<source>-<target>.json` relates two schemes. One file serves both directions.

```json
{"source": "heb", "target": "eng", "seededFrom": {},
 "entries": [{"book": "PSA", "kind": "superscriptionAsVerse1", "source": [3, 2], "target": [3, 1]},
             {"book": "PSA", "kind": "superscriptionAsVerse1", "source": [3, 1]},
             {"book": "NUM", "kind": "targetOnly", "target": [29, 40]}]}
```

Each entry names a book, a kind, and one or both sides. A side is `[chapter, verse]` and names a verse that exists in that side's scheme. An entry with both sides is a **pair**. An entry with one side is **one-sided**.

| Kind in the file | `MappingKind` | Sides | Meaning |
|---|---|---|---|
| `superscriptionAsVerse1` | `superscriptionAsVerse1` | Both, or source only | The source numbers a Psalm title as verse 1. |
| `chapterBoundarySplit` | `chapterBoundarySplit` | Both | The schemes break chapters at different verses. |
| `relocated` | `relocated` | Both | The schemes print the verse in different places. |
| `splitVerse` | `splitVerse` | Both | One scheme splits a verse that the other keeps whole. |
| `sourceOnly` | `extraVerse` | Source only | The verse exists only in the source scheme. |
| `targetOnly` | `extraVerse` | Target only | The verse exists only in the target scheme. |

These files exist in format version 1.

| File | Entries | Seeded from |
|---|---|---|
| `heb-eng.json` | 1404 | bible-api `data/versification-map.json` |
| `grc-eng.json` | 5 | Checked by hand against the TCGNT and KJV sources |

`heb-eng.json` names the verses that cross a chapter boundary, such as Hebrew Exodus 7:26 to 7:29, which are English 8:1 to 8:4. It does not name the verses that shift within a chapter after them. Hebrew Exodus 8:1 is English 8:5, but it falls back to the same number. So 107 English verses are reached from two Hebrew verses, and 110 English verses are reached from none. A known-issue test in `MappingTests` tracks this until the seed is corrected.

### Resolving a verse

`VersificationMapping.map` takes a verse of the source scheme and returns a `MappedVerse`. The same rules apply in the reverse direction, with source and target swapped.

1. If the verse is not in the source scheme, the result is `nil`.
2. If the target scheme does not contain the book, the result is `bookAbsent`.
3. If pairs name the verse on this side, the result is `mapped`, with every counterpart in canonical order. A pair wins over a one-sided entry for the same verse.
4. If a one-sided entry names the verse on this side, the result is `absent`, with the entry's kind.
5. Otherwise the result is `same`. The verse has the same chapter and verse number in both schemes.

A verse can have more than one counterpart in either direction. English 3 John 1:14 maps to Greek 3 John 1:14 and 1:15. So `mapped` carries an array. All pairs for one verse share one kind, and a loader rejects a file where they do not.

`Versification.mapping(from:to:)` returns the mapping for two schemes. It reads `<from>-<to>.json`, or reverses `<to>-<from>.json`. A scheme maps to itself with every verse `same`. Two schemes with no file have no mapping, and the result is `nil`.

## Canon package

`canon.sqlite` holds the tables in the `Canon` and `Versification` Swift types. Its `meta` table has the same shape as an edition package's. Its `format_version` is 1.

| Table | Rows |
|---|---|
| `meta` | `format_version`. The schema inserts it. |
| `sections` | One per section group, with `position` from 1. `id` is the `Section` raw value, such as `wisdomAndPoetry`. |
| `books` | One per defined book, all 86. |
| `aliases` | One per name that finds a book. The names are the id, the name, the short name, and each alias. An alias is unique, ignoring ASCII case. |
| `schemes` | One per scheme id. |
| `verse_counts` | One per chapter per scheme. |
| `mappings` | One per mapping entry, in the file's direction. `kind` is the `MappingKind` raw value, so `sourceOnly` and `targetOnly` become `extraVerse`. A missing side is `NULL`. |

Section groups, in order, are Law, History, Wisdom and Poetry, Major Prophets, Minor Prophets, Gospels and Acts, Paul's Letters, General Letters, Prophecy, and Apocrypha.

A book's short name is its SBL Handbook of Style abbreviation, such as `Gen`, `1 Sam`, `Ps`, `Matt`, and `Phlm`.

`CanonSchema.ddl` holds the schema. A test checks that this block matches it.

```sql
CREATE TABLE meta (
  key TEXT PRIMARY KEY NOT NULL,
  value TEXT NOT NULL
) WITHOUT ROWID;

INSERT INTO meta (key, value) VALUES ('format_version', '1');

CREATE TABLE sections (
  id TEXT PRIMARY KEY NOT NULL,
  position INTEGER NOT NULL UNIQUE,
  name TEXT NOT NULL
);

CREATE TABLE books (
  id TEXT PRIMARY KEY NOT NULL,
  canon_order INTEGER NOT NULL UNIQUE,
  testament TEXT NOT NULL CHECK (testament IN ('OT', 'NT', 'AP')),
  section TEXT NOT NULL REFERENCES sections (id),
  name TEXT NOT NULL,
  short_name TEXT NOT NULL,
  chapters INTEGER NOT NULL CHECK (chapters BETWEEN 1 AND 999)
);

CREATE TABLE aliases (
  alias TEXT PRIMARY KEY NOT NULL COLLATE NOCASE,
  book TEXT NOT NULL REFERENCES books (id)
);

CREATE TABLE schemes (
  id TEXT PRIMARY KEY NOT NULL
);

CREATE TABLE verse_counts (
  scheme TEXT NOT NULL REFERENCES schemes (id),
  book TEXT NOT NULL REFERENCES books (id),
  chapter INTEGER NOT NULL CHECK (chapter BETWEEN 1 AND 999),
  verses INTEGER NOT NULL CHECK (verses BETWEEN 1 AND 999),
  PRIMARY KEY (scheme, book, chapter)
) WITHOUT ROWID;

CREATE TABLE mappings (
  source TEXT NOT NULL REFERENCES schemes (id),
  target TEXT NOT NULL REFERENCES schemes (id),
  book TEXT NOT NULL REFERENCES books (id),
  kind TEXT NOT NULL CHECK (kind IN ('superscriptionAsVerse1', 'chapterBoundarySplit', 'relocated', 'splitVerse', 'extraVerse')),
  source_chapter INTEGER,
  source_verse INTEGER,
  target_chapter INTEGER,
  target_verse INTEGER,
  CHECK ((source_chapter IS NULL) = (source_verse IS NULL)),
  CHECK ((target_chapter IS NULL) = (target_verse IS NULL)),
  CHECK (source_chapter IS NOT NULL OR target_chapter IS NOT NULL)
);

CREATE INDEX mappings_by_source ON mappings (source, target, book, source_chapter, source_verse);
CREATE INDEX mappings_by_target ON mappings (source, target, book, target_chapter, target_verse);
```

## Compatibility

A reader supports a set of format versions. It opens a package only if `meta.format_version` is in that set.

- An additive change keeps the format version and raises `format_minor`. Additive means a reader that knows the format version can ignore the change. Examples are a new table, a new nullable column, a new `meta` key, and a new `RunStyle` bit.
- Any other change raises `format_version`. Examples are a new chapter item, a new block kind, a new chapter encoding, and a changed column.
- The manifest lists each package's `format_version` and `min_app_version`. The app hides a package whose `format_version` it does not support. `min_app_version` is the oldest app version that supports it.

## Manifest

`manifest.json` lists every package. Phase 0 step 6 defines it. Its fields are `id`, `kind`, `name`, `language`, `format_version`, `min_app_version`, `size`, `compressed_size`, `sha256`, `url`, and `released`.

## Change log

### Format version 1 (unreleased)

- First definition: edition package schema, chapter model, JSON reference encoding, versification schemes `eng`, `heb`, and `grc`, and the canon package schema.
