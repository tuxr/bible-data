# bible-data format

Format version 1 (unreleased)

This document defines the files that `bible-pack` writes and the app reads. The `BibleFormat` Swift module implements every rule here. `bible-pack` and the app's `BibleKit` both link `BibleFormat`, so the writer and the reader share one implementation.

## Scope and principles

The format has four kinds of file. Each is a read-only SQLite 3 database, and each says which kind it is in its `meta` table.

- An **edition package** holds one edition of scripture, such as the BSB or the WLC.
- A **words package** holds the word tags of one tagged edition: Strong's number, morphology, lemma, gloss, and parts, by verse and word position.
- A **lexicon package** holds the Greek or the Hebrew dictionary that every words package in that language points into.
- The **canon package**, `canon.sqlite`, holds the book table, the versification schemes, and the mappings between schemes. The app bundles it.

These rules hold for every file.

- A package is immutable. A new build of an edition is a new file with a new version. Nothing edits a released package.
- An edition or words package carries one edition. Adding an edition never changes another edition's file.
- Book ids are USFM 3-letter codes, such as `GEN`, `1SA`, and `REV`.
- Anchors that outlive a package, such as marks, notes, and reading positions, use the `eng` scheme. An edition in another scheme reaches `eng` through a mapping.
- Packages carry only the 66 books of the Protestant canon. The canon defines 86 books, so the Apocrypha can ship later without a format change.

## File names

An edition package is named `<id>-<version>.bible`.

- `<id>` is the edition id, a lowercase short code such as `bsb`, `wlc`, or `tcgnt`.
- `<version>` is the package version, `<yyyy.mm>[.<n>]`: the year and month of the build, then `.n` for the nth rebuild released in the same month, as in `2026.10`, `2026.10.1`, and `2026.10.2`. `n` runs from 1 to 999 with no leading zero. Versions order by year, month, then `n`, with no `n` first. `PackageVersion` parses and orders them, and `meta.version` holds the same value, so a renamed file is caught.
- A release tag is `v<version>`, and every package of the release carries that version. A published package never changes, so a second release in a month takes the next `n`.

The download is `<id>-<yyyy.mm>.bible.xz`, the package compressed with Apple's `COMPRESSION_LZMA`. That algorithm writes an xz stream with no integrity check field, which `xz -t` accepts. The app decompresses it with the same framework and accepts the result only if its SHA-256 matches the manifest.

A words package is named `<id>-<version>.words`, after the edition it tags, such as `wlc-2026.10.words`. A lexicon package is named `lexicon-<greek|hebrew>-<version>.lexicon`. Each has an `.xz` download beside it, made the same way.

The canon package is published as `canon-<version>.sqlite`, with an `.xz` beside it. The app bundles a copy as `canon.sqlite`.

### `meta.kind`

Every package's schema inserts a `kind` row into `meta`: `edition`, `words`, `lexicon`, or `canon`. A reader reads it before any other table and refuses a file of a kind it did not expect. `PackageKind` holds the values. `bible-pack validate` picks its checks by it.

## Edition package

### Tables

| Table | Rows | Purpose |
|---|---|---|
| `meta` | One per key | Format version and build provenance. Its shape never changes. |
| `edition` | Exactly one | What the edition is, where it came from, and how it is encoded. |
| `books` | One per book present | The books as this edition names them. |
| `chapters` | One per chapter | The encoded chapter content. |
| `verses` | One per verse | Plain text for search results, copy, and anchoring, and the folded text search indexes. |
| `verses_fts` | One per verse | The FTS5 search index over the folded text. |
| `notes` | One per note | Footnotes, cross-references, and translator notes. |

### `meta`

`meta` is a key and value table. A reader reads `meta` before any other table, because its shape is the same in every format version.

| Key | Value |
|---|---|
| `format_version` | The format version as a decimal integer. The schema inserts it. |
| `format_minor` | The additive revision within the format version. The schema inserts it. |
| `kind` | `edition`. The schema inserts it. |
| `version` | The package version, as in the file name. |
| `built_at` | The build time, ISO 8601 in UTC. |
| `builder_version` | The `bible-pack` version that wrote the file. |
| `source_lock` | The `sources.lock.json` entry for the edition's source, as JSON with sorted keys. |
| `absent_verses` | The verses of the edition's scheme that the edition does not print, as a JSON array of `BOOK C:V` strings in canonical order, such as `["LUK 17:36","ACT 8:37"]`. `[]` when there are none. `AbsentVerses.decode` reads it. |

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
| `text_plain` | The verse text with no markup, notes, or verse numbers. The app shows and copies it. |
| `text_search` | `text_plain` folded for search by `SearchText`, or `NULL` when folding leaves it unchanged. See Search. |

Book, chapter, and verse use the edition's own versification.

A verse bridge such as 1-2 is one row, at its first verse. A verse that `meta.absent_verses` lists has no row.

`text_search` is `NULL` for every Latin-script verse, so an English edition does not store its text twice. A `CHECK` constraint rejects a `text_search` equal to `text_plain`, so each verse has one way to be stored.

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

`verses_fts` is an FTS5 table with external content. Its content is the `verses_search` view, which gives each verse's `text_search`, or its `text_plain` where `text_search` is `NULL`. The index stores no second copy of the text. Its rowid is the verse row id, so results arrive in canonical order.

- The tokenizer is `unicode61 remove_diacritics 2`. It folds case and Latin diacritics, so `created` finds `créated`.
- The tokenizer does not fold Hebrew points or polytonic Greek accents and breathings, so `SearchText` folds them first. With the folded column, the query `בראשית` finds `בְּרֵאשִׁית` and `αρχη` finds `ἀρχῇ`.
- Three triggers keep the index in step with `verses` on insert, delete, and update.

`SearchText.normalize(_:script:)` folds by `edition.script`. The app folds a query with `SearchText.normalizeQuery`, which applies the same rule.

| Script | Rule |
|---|---|
| `Latn` | Unchanged. The tokenizer folds case and diacritics. |
| `Hebr` | Remove the points and cantillation marks, U+0591 to U+05BD, U+05BF, U+05C1, U+05C2, U+05C4, U+05C5, and U+05C7. Maqaf U+05BE, paseq U+05C0, sof pasuq U+05C3, and nun hafukha U+05C6 stay. They are punctuation, so the tokenizer splits on them. |
| `Grek` | Decompose to NFD, remove every combining mark, lowercase, then fold final sigma `ς` and lunate sigma `ϲ` to `σ`. Lowercasing comes first because a Greek-locale lowercase turns a word-final `Σ` into `ς`. `λόγος` becomes `λογοσ`. |

### Schema

`PackageSchema.ddl` holds the schema. A test checks that this block matches it.

```sql
CREATE TABLE meta (
  key TEXT PRIMARY KEY NOT NULL,
  value TEXT NOT NULL
) WITHOUT ROWID;

INSERT INTO meta (key, value) VALUES ('format_version', '1');
INSERT INTO meta (key, value) VALUES ('format_minor', '0');
INSERT INTO meta (key, value) VALUES ('kind', 'edition');

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
  text_search TEXT,
  UNIQUE (book, chapter, verse),
  CHECK (id % 1000 = verse AND id / 1000 % 1000 = chapter),
  CHECK (text_search IS NULL OR text_search <> text_plain)
);

CREATE VIEW verses_search AS
SELECT id, coalesce(text_search, text_plain) AS text_search FROM verses;

CREATE VIRTUAL TABLE verses_fts USING fts5 (
  text_search,
  content = 'verses_search',
  content_rowid = 'id',
  tokenize = 'unicode61 remove_diacritics 2'
);

CREATE TRIGGER verses_fts_insert AFTER INSERT ON verses BEGIN
  INSERT INTO verses_fts (rowid, text_search) VALUES (new.id, coalesce(new.text_search, new.text_plain));
END;

CREATE TRIGGER verses_fts_delete AFTER DELETE ON verses BEGIN
  INSERT INTO verses_fts (verses_fts, rowid, text_search) VALUES ('delete', old.id, coalesce(old.text_search, old.text_plain));
END;

CREATE TRIGGER verses_fts_update AFTER UPDATE ON verses BEGIN
  INSERT INTO verses_fts (verses_fts, rowid, text_search) VALUES ('delete', old.id, coalesce(old.text_search, old.text_plain));
  INSERT INTO verses_fts (rowid, text_search) VALUES (new.id, coalesce(new.text_search, new.text_plain));
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

### Edition metadata

`editions/<id>.json` says what an edition is. `EditionMetadata` decodes it. Its fields are the `edition` columns `id`, `name`, `abbreviation`, `language`, `script`, `direction`, `versification`, `license`, `attribution`, and `publisher`, and `source`, the edition's key in `sources.lock.json`. A file is refused when its source is not in the lock, its `script` or `versification` is unknown, or its `direction` disagrees with its script. `bible-pack` also refuses a file whose `versification` differs from the scheme the edition parses in.

### Building and validating a package

`bible-pack build <id>` writes the package. It parses the edition from its locked source and refuses a parse with warnings. It applies `PackageSchema.ddl` to a fresh file with a 4096-byte page size and inserts every row in one transaction: `meta`, `edition`, books in canonical order, chapters and verses in stream order, and notes by chapter and number. It then runs the FTS5 `optimize` command and `VACUUM`, and leaves the file in rollback journal mode. It writes the package and its `.xz` beside their destinations and renames each into place, so neither name is ever a partial file. Two builds from the same source with the same `--built-at` and `--encoding` are byte-identical, and so are their `.xz` files.

`bible-pack validate <path>` is the acceptance check. It opens the package read-only and runs these checks in order. It exits 1 on the first failure and names the check.

1. `PRAGMA integrity_check` and `PRAGMA foreign_key_check`.
2. `meta.format_version` and `edition.format_version` equal `PackageFormat.version`.
3. `edition` has one row, with a known script, a direction that matches it, a known versification, a known chapter encoding, and the `meta.built_at` time, and `meta.version` is a package version.
4. Every book is defined, its `canon_order` is the canon's, and its chapter count is the scheme's. `edition.canon` lists the books.
5. `chapters` has every chapter of every book present, and every blob decodes with the named encoding.
6. Each chapter's `PlainText.verses` equals its `verses` rows, and the verses it prints are the scheme's minus `meta.absent_verses`.
7. Every verse row id follows the formula, and every `text_search` is what `SearchText` gives for its `text_plain`.
8. The FTS5 `integrity-check` command passes on an in-memory copy, since SQLite runs it as a write. A sample query by script finds its verse: `beginning` finds GEN 1:1 in Latin, `בראשית` finds GEN 1:1 in Hebrew, and `αρχη` finds JHN 1:1 in Greek.
9. Every note caller in every chapter has a `notes` row with the same number, kind, and caller, and every note has a caller.
10. The `.xz` beside the package, when present, decompresses to bytes with the package's SHA-256.

`--against-source` parses the edition again from `.sources/` and compares every chapter's decoded items, and every `meta`, `edition`, `books`, `verses`, and `notes` row, to the parse. A package ships only if it passes with `--against-source`.

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
- A `noteCaller` item that follows a heading, title, or speaker with no `block` item between belongs to that label. Label runs hold no callers, so a note inside a label sits right after it.

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
| 1 | `binary` | A tagged item stream, below. `BinaryChapterCodec`. |
| 2 to 255 | Reserved | For later encodings. |

The Phase 0 step 4 benchmark, `docs/benchmarks/chapter-codec-2026-10-30.md`, compares the encodings. No package is released before step 4 lands.

Every encoding meets two rules. Decoding an encoded chapter gives an equal `Chapter`. Encoding the same chapter twice gives the same bytes.

#### Encoding 1, `binary`

A blob is a varint item count, then that many items, then nothing. Every integer is an unsigned LEB128 varint: 7 bits per byte, low bits first, the high bit set on every byte but the last, at most 10 bytes. A string is a varint byte length, then that many bytes of UTF-8. A run is its text as a string, then its `style` raw value as a varint, then its `word` as a varint, 0 for nil.

Each item starts with one tag byte. The high nibble is the item kind and the low nibble its variant.

| Tag | Item | Then |
|---|---|---|
| `0x10` to `0x15` | `block`: `paragraph`, `flush`, `indented`, `rightAligned`, `centered`, `blankLine` | Nothing. |
| `0x19` to `0x1B` | `block(poetry(level:))`, level 1 to 3 in the low two bits | Nothing. |
| `0x1D` to `0x1F` | `block(list(level:))`, level 1 to 3 in the low two bits | Nothing. |
| `0x21` to `0x23` | `heading(level:)`, level in the low nibble | A varint run count, then the runs. |
| `0x30` | `title` | A varint run count, then the runs. |
| `0x40` | `speaker` | A varint run count, then the runs. |
| `0x50` | `verse` | `number`, then `through`, 0 for nil. |
| `0x60` | `text` | One run. |
| `0x70` to `0x72` | `noteCaller`: `footnote`, `crossReference`, `translatorNote` | `number`, then `glyph` as a string. |

Every other tag value is reserved, so a new item kind or block kind takes a free value with a format version bump. The blob has no string table. Its strings are inline, in stream order.

A decoder rejects a blob that ends early, holds bytes after its last item, has a reserved tag, has a level of 0 or above 3 (`0x18`, `0x1C`, `0x20`, `0x24` to `0x2F`), holds invalid UTF-8, has a varint longer than 10 bytes or a value too large for its field (a `style` above 65535), or has a bridge whose `through` is not greater than its `number`. It never traps on bad bytes. An encoder rejects a negative number, a `word` of 0, and a `through` of 0, because 0 means nil.

The first five items of BSB Genesis 1, encoded as a chapter of their own, are 85 bytes. `BinaryChapterCodecTests` pins them. The real chapter has 109 items, so its blob starts with `6D`.

```
05                                  5 items
22 01 0C 54 68 65 ... 6F 6E 00 00   heading level 2, 1 run: 12 bytes "The Creation", style 0, word nil
71 01 01 61                         noteCaller crossReference, number 1, glyph 1 byte "a"
10                                  block paragraph
50 01 00                            verse 1, through nil
60 37 49 6E 20 ... 2E 00 00         text: 55 bytes "In the beginning ... earth.", style 0, word nil
```

## Parsing rules

`bible-pack` parses USFM 3 and USFX sources into the chapter model. Both parsers read one marker table, so a USFM marker and the USFX element of the same name mean the same thing. These rules decide what a package holds.

### Headings, titles, and speakers

| Markers | Item |
|---|---|
| `ms`, `ms1` to `ms3`, `mr` | `heading` level 1 |
| `s`, `s1`, `sr` | `heading` level 2 |
| `s2` to `s4` | `heading` level 3 |
| `d`, `qa` | `title` |
| `sp` | `speaker` |

A USFX `s` or `q` element with no level in its `style` takes its `level` attribute, and level 1 when it has none. The BSB uses `ms`, `s1`, and `s2`, so three levels keep every distinction it draws.

A verse marker inside a title, as in the BSB's `\d \v 1 A Psalm of David.`, opens the verse when the title ends. The title is not verse text.

### Plain text

`PlainText.verses(of:)` derives `verses.text_plain`. The app uses the same function, so search, copy, and the reader agree.

1. Join the `text` runs of each verse in stream order. Headings, titles, speakers, and note callers are not verse text.
2. Put one space at each block boundary, except after a run that ends in an em dash. A poetry line that ends in an em dash runs on into the next with no space, as the BSB's own text prints it.
3. Collapse each run of whitespace to one space.
4. Remove a space before `.`, `,`, `;`, `:`, `!`, and `?`.
5. Trim the result.

Text before the first verse marker belongs to no verse. Note text follows rules 3 to 5.

No step applies Unicode normalization, in plain text or anywhere else. NFC reorders Hebrew points and accents, so the text keeps the publisher's code points.

### Notes

- A note's `number` is its place in the chapter's reading order, from 1. Its caller in the stream has the same number.
- A note's `verse` is the verse open where its caller sits, or 0 before verse 1. A note in a title before verse 1 is at 0.
- The USFM caller `+` becomes a letter by note number: `a` to `z`, then `aa`. The caller `-` becomes an empty glyph. Any other caller is kept.
- A footnote's text drops `fr` and `xo`, the reference its caller already implies. It keeps the words of `fq`, `fqa`, and `fk`, and the verse numbers of `fv`.
- An `r` line of parallel passages becomes a `crossReference` note on the heading it follows, without its enclosing parentheses.
- `targets` come from `\ref text|TARGET\ref*` and USFX `<ref tgt>`. A target is `BOOK C:V`, `BOOK C:V-V`, or `BOOK C:V-C:V`, or `BOOK V` and `BOOK V-V` in a one-chapter book. A target with no book id names a book outside the canon, such as 1 Enoch, and records nothing. Any other target that does not parse is dropped with a warning.

### Verse numbers

- A bridge such as `\v 1-2` is one `verse` item with `number` 1 and `through` 2.
- A letter suffix is dropped. `\v 12a` opens verse 12, and a later `\v 12b` continues it with no new item.
- A verse of the edition's scheme that the source does not print is **absent**. `ParsedBook.absentVerses` lists it, so validation can allow it. The BSB has 16 absent verses, such as Matthew 17:21, which it gives in a footnote. The TCGNT has 4: Luke 17:36, Acts 8:37, Acts 15:34, and Acts 24:7. The WLC has none.
- A printed verse outside the scheme is a warning.

### Words

An edition is word-tagged when its source has `w` markers. In a tagged edition, every word gets a position in its verse, starting at 1, and a `WordTag`. A word the source leaves untagged, such as the WLC's `לָהֶ֖ם` between two `<w>` elements, keeps its position with no Strong's number. Spaces, punctuation such as maqaf, sof pasuq, paseq, and the Greek koronis, and the Masoretic paragraph letters `פ` and `ס` get no position.

### Character styles

In USFM, a paragraph marker ends every character style left open, as USFM 3 says. A style crosses verse markers and notes inside its paragraph. In USFX, the element nesting decides.

### Edition repairs

Some publisher files need repairs. Each edition names its own, and the generic parsers never apply them.

| Edition | Repair |
|---|---|
| `bsb` | Rewrites three misused markers to their USFM 3 meaning. `\d` outside the Psalms becomes `\p`. Its one use is Zechariah 12:1, which is verse text. `\mr` becomes `\qd`. Its one use is Habakkuk 3:19's closing note. A `\qr` line of "Selah" or "Higgaion Selah" gets `\qs`. |
| `bsb` | Removes bsb2usfm's typesetting artifacts from runs and notes: spaced em dashes, `[’’]`, brackets, a stray `vvv`, `...` before a number or a parenthesis, the typo `evenif`, spaces inside parentheses and quotes, and a missing space after punctuation. |
| `wlc` | Restores 11 words whose markup eBible escaped into the text, such as Deuteronomy 6:4's `'l s="H8085"'`. Each becomes a tagged word again. The large, small, and suspended letter marks are dropped. |
| `tcgnt` | Removes a stray `<ft>` around a footnote at John 8:10. |

### Warnings

A parse returns its warnings: unknown markers, unreadable targets, verses that start twice, and verses outside the scheme. Every locked edition parses with none.

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
 "entries": [{"book": "PSA", "kind": "superscriptionAsVerse1", "source": [3, 1]},
             {"book": "PSA", "kind": "renumbered", "source": [3, 2], "target": [3, 1]},
             {"book": "ISA", "kind": "splitVerse", "source": [63, 19], "target": [63, 19]},
             {"book": "ISA", "kind": "splitVerse", "source": [63, 19], "target": [64, 1]},
             {"book": "NEH", "kind": "extraVerse", "target": [7, 68]}]}
```

Each entry names a book, a kind, and one or both sides. A side is `[chapter, verse]` and names a verse that exists in that side's scheme. An entry with both sides is a **pair**. An entry with one side is **one-sided**.

The file spells each kind as its `MappingKind` raw value. Kinds are direction-neutral, so the reversed mapping keeps them.

| Kind | Sides | Meaning |
|---|---|---|
| `renumbered` | Both | The verse has a different number in each scheme. Most come from a chapter that starts at a different verse, and the shift runs to the chapter's end. |
| `superscriptionAsVerse1` | One | One scheme numbers a Psalm title as a verse, and the other leaves the title unnumbered. |
| `splitVerse` | Both | One verse in one scheme holds the text of two or more verses in the other. Each piece is its own pair, and every pair has this kind. |
| `relocated` | Both | The schemes print the same text in different places. |
| `extraVerse` | One | Only one scheme has the verse, and it is not a Psalm title. |

A loader rejects an entry whose sides do not match its kind, and a `renumbered` pair that keeps the same number.

These files exist in format version 1.

| File | Entries | Source |
|---|---|---|
| `heb-eng.json` | 2044 | TVTMS, `English KJV` and `Hebrew` columns |
| `grc-eng.json` | 5 | Checked by hand against the TCGNT and KJV sources |

`heb-eng.json` is derived by `Tools/derive-heb-eng-mapping.py` from STEPBible's TVTMS (Translators Versification Traditions with Methodology for Standardisation), at [STEPBible/STEPBible-Data](https://github.com/STEPBible/STEPBible-Data) commit `be4191f0`. The licence asks users to get the file from STEPBible, so the repo does not include it. The tool takes the file path as an argument and checks it against the SHA-256 in `seededFrom`. Credit it as: "Versification data derived from TVTMS by STEPBible.org, Tyndale House Cambridge, CC BY 4.0". `Versification.attribution` holds this line for the app's About screen.

The tool writes 1964 `renumbered`, 67 `superscriptionAsVerse1`, 12 `splitVerse`, and 1 `extraVerse` entries. Before it writes the file, it rebuilds the mapping from the entries and checks it against `heb.json` and `eng.json`:

- Every `heb` verse maps to `eng` verses that exist, or has a one-sided entry.
- Every `eng` Old Testament verse is reached by a `heb` verse, or has a one-sided entry.
- An `eng` verse that two or more `heb` verses reach is the target of `splitVerse` pairs.
- Per book, the one-sided and split entries account for the difference in verse totals: NUM, 1SA, 1KI, and 1CH +1, NEH and ISA -1, PSA +66.

TVTMS's Greek column follows the critical text, not TCGNT's numbering, so `grc-eng.json` stays a hand seed. TVTMS agrees with it that Greek 3 John 1:14 and 1:15 are English 1:14.

### Resolving a verse

`VersificationMapping.map` takes a verse of the source scheme and returns a `MappedVerse`. The same rules apply in the reverse direction, with source and target swapped.

1. If the verse is not in the source scheme, the result is `nil`.
2. If the target scheme does not contain the book, the result is `bookAbsent`.
3. If pairs name the verse on this side, the result is `mapped`, with every counterpart in canonical order.
4. If a one-sided entry names the verse on this side, the result is `absent`, with the entry's kind.
5. Otherwise the result is `same`. The verse has the same chapter and verse number in both schemes.

A verse can have more than one counterpart in either direction. English 3 John 1:14 maps to Greek 3 John 1:14 and 1:15. So `mapped` carries an array. On each side, a verse is named by pairs of one kind or by one one-sided entry. A loader rejects a file where pairs for one verse have different kinds, or where a verse has both pairs and a one-sided entry.

`Versification.mapping(from:to:)` returns the mapping for two schemes. It reads `<from>-<to>.json`, or reverses `<to>-<from>.json`. A scheme maps to itself with every verse `same`. Two schemes with no file have no mapping, and the result is `nil`.

## Canon package

`canon.sqlite` holds the tables in the `Canon` and `Versification` Swift types. Its `meta` table has the same shape as an edition package's. Its `format_version` is 1.

| Table | Rows |
|---|---|
| `meta` | One per key. See below. |
| `sections` | One per section group, with `position` from 1. `id` is the `Section` raw value, such as `wisdomAndPoetry`. |
| `books` | One per defined book, all 86. |
| `aliases` | One per name that finds a book. The names are the id, the name, the short name, and each alias. An alias is unique, ignoring ASCII case. |
| `schemes` | One per scheme id. |
| `verse_counts` | One per chapter per scheme. |
| `mappings` | One per mapping entry, in the file's direction. `kind` is the `MappingKind` raw value, so `sourceOnly` and `targetOnly` become `extraVerse`. A missing side is `NULL`. |

Section groups, in order, are Law, History, Wisdom and Poetry, Major Prophets, Minor Prophets, Gospels and Acts, Paul's Letters, General Letters, Prophecy, and Apocrypha.

A book's short name is its SBL Handbook of Style abbreviation, such as `Gen`, `1 Sam`, `Ps`, `Matt`, and `Phlm`.

### Canon `meta`

| Key | Value |
|---|---|
| `format_version` | `CanonSchema.version` as a decimal integer. The schema inserts it. |
| `kind` | `canon`. The schema inserts it. |
| `version` | The package version, as in the published file name. |
| `built_at` | The build time, ISO 8601 in UTC, such as `2026-10-29T00:00:00Z`. |
| `builder_version` | The `bible-pack` version that wrote the file. |
| `versification_attribution` | The STEPBible credit, `Versification.attribution`. The app shows it in About. |

### Building and accepting

`bible-pack canon build` writes the package. It applies `CanonSchema.ddl` to a fresh file with a 4096-byte page size, inserts every row in one transaction, runs `VACUUM`, and leaves the file in rollback journal mode, so the result is one self-contained file. It writes beside the destination and renames into place, so the destination is never a partial file, then writes the `.xz` download beside it the same way as an edition package's.

The build is deterministic. Rows go in a fixed order: sections in `Section` order, books in canonical order, aliases by book and then by `lookupNames` order, verse counts by scheme, book, and chapter, and mappings by file and then by entry order. Two builds from the same tables with the same `--version` and `--built-at` are byte-identical, and so are their `.xz` files.

`bible-pack canon validate <path>` is the acceptance check. It opens the file read-only and runs `PRAGMA integrity_check` and `PRAGMA foreign_key_check`. It checks `meta`, including `kind`, then compares every table to the `Canon` and `Versification` types row by row. It checks that every verse count is from 1 to 999 and that each scheme's totals match `Versification.counts(for:)`, and that the `.xz` beside it, when present, decompresses to its bytes. It exits 1 on the first failure and names the table and the first differing row. A canon package ships only if it passes.

`CanonSchema.ddl` holds the schema. A test checks that this block matches it.

```sql
CREATE TABLE meta (
  key TEXT PRIMARY KEY NOT NULL,
  value TEXT NOT NULL
) WITHOUT ROWID;

INSERT INTO meta (key, value) VALUES ('format_version', '1');
INSERT INTO meta (key, value) VALUES ('kind', 'canon');

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
  kind TEXT NOT NULL CHECK (kind IN ('renumbered', 'superscriptionAsVerse1', 'splitVerse', 'relocated', 'extraVerse')),
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

## Words package

A words package carries the word tags of one tagged edition, the WLC or the TCGNT. Its rows are keyed by the edition's own verse row id and the word's position in the verse, the same coordinates as `Run.word` in the edition package. A mark on a word and a tap on it for word study name the same row.

### Words `meta`

| Key | Value |
|---|---|
| `format_version`, `format_minor` | As in the edition package. The schema inserts them. |
| `kind` | `words`. The schema inserts it. |
| `version` | The package version, as in the file name. |
| `built_at` | The build time, ISO 8601 in UTC. |
| `builder_version` | The `bible-pack` version that wrote the file. |
| `edition` | The edition id, such as `wlc`. |
| `edition_source_sha256` | The SHA-256 of the edition's locked source zip. A words file belongs to exactly the text it was aligned to. |
| `attribution` | A JSON array of the credit lines of exactly the sources the package used. The app shows them in About and the word panel. |
| `sources` | A JSON array of the `sources.lock.json` ids it used, the edition first. |

### `words`

| Column | Meaning |
|---|---|
| `verse_id` | The verse row id, `PackageSchema.verseRowID`, in the edition's own versification. The same id the edition package's `verses` row has. |
| `position` | The word's position in the verse, from 1, equal to `Run.word`. Positions run 1 to n in every verse with no gap. |
| `surface` | The word as the edition prints it, with its points and accents. |
| `strong` | The Strong's id, in the stored form below, or `NULL`. |
| `morph` | The morphology code as its source writes it, or `NULL`. OSHB codes such as `HR/Ncfsa` for the WLC, Robinson codes such as `N-NSM` for the TCGNT. The app decodes them. |
| `lemma` | The dictionary form, the same value the lexicon entry's `lemma` holds, or `NULL`. |
| `gloss` | A short English gloss of the word in this verse, or `NULL`. |
| `parts` | For a Hebrew word OSHB splits into prefixes, a stem, and suffixes, a JSON array of its pieces in reading order. `NULL` for any other word. |

Each element of `parts` is an object with `strong`, `morph`, `gloss`, and `surface`, each left out when absent. `WordParts.encode` writes it with sorted keys. The pieces are OSHB's, one per `/` of its code. `morph` is the piece of the word's OSHB code: `HC/Td/Ncfsa` gives `HC`, `HTd`, and `HNcfsa`, since OSHB writes the language letter once. The stem, OSHB's last piece before any suffix, carries the word's own `strong`. When TAHOT splits the word into as many pieces, a prefix or suffix carries TAHOT's code for it, `H9001` to `H9049`, which no lexicon entry has, and every piece carries TAHOT's `gloss`. When the counts differ, the pieces have no `gloss` and only the stem has a `strong`. A word OSHB tags as two elements, such as `לְמַבָּרִ֥אשׁוֹנָ֖ה` in 1 Chronicles 15:13, has two stems, and each carries its own OSHB lemma's id. `surface` is the piece of the word's own surface, when its letters split cleanly into the pieces' letter counts.

```json
[{"gloss":"in","morph":"HR","strong":"H9003","surface":"בְּ"},{"gloss":"beginning","morph":"HNcfsa","strong":"H7225","surface":"רֵאשִׁ֖ית"}]
```

### Strong's ids

`StrongID` reads and writes every Strong's id the format stores. The app keys lexicon lookups with it.

- An id is `G` or `H` and the number, zero-padded to four digits: `G3056`, `H0776`, `G0746`. A number above 9999 keeps its digits, as in `G10005`.
- A Hebrew id keeps an extended Strong's homonym letter `A` to `F`, upper case, as in `H1254A`.
- Any other trailing letter is a STEPBible disambiguation of one entry and is dropped: `H0430G` is `H0430`, `G3708H` is `G3708`. A Greek id never has a letter.
- `StrongID.isCanonical` is true only for the stored form, so `H430`, `H0430G`, and `H1254a` are not stored ids.

The lexicons key their entries at Strong's level, with no homonym letter, because Strong's dictionary does not split homonyms and the editions' own tags carry none. TAHOT's `H1254A` is stored as `H1254`.

### Building words

`bible-pack build-words <edition>` parses the edition as `build` does and takes every word's position and surface from the parse. It never renumbers them. It then aligns the parse with the edition's word sources.

WLC:

- `morph` and the `parts` pieces are OSHB's, from the `oshb` file set: the `wlc/` books of `github.com/openscriptures/morphhb`. The eBible USFX carries an OSHB `m` attribute on only 2,352 of its 299,878 tagged words, and on 215 of those it is an older code than OSHB's, so the build reads no `m` attribute.
- OSHB's words are read per verse in reading order. Each `<w>` is a word, its text and its `morph` split at `/` into pieces, and its `lemma` gives each prefix and stem a piece; a suffix has none. Two `<w>` elements with nothing between them are one WLC word that OSHB divides for exegesis. A note's contents are not text: the WLC prints the Ketiv, OSHB's `<w type="x-ketiv">`, and keeps the Qere in a `<note type="variant">`, which the reader skips, as it skips a Qere with no Ketiv.
- `strong` is the parser's, from the edition's USFX tags. Where the parser has none, it is OSHB's stem lemma at Strong's level, then TAHOT's stem.
- TAHOT supplies `gloss`, and the prefix and suffix codes and glosses of `parts`. TAHOT's rows are matched by verse: the Hebrew reference in parentheses where TAHOT gives one, else the reference as written. Rows of type `X`, words other manuscripts add, are left out.
- Within a verse, OSHB's words and then TAHOT's rows each pair in order when the counts agree and every pair's letters are close. Otherwise the verse is aligned by its letters with points, cantillation, and OSHB's `/` removed, `SearchText.normalize` with `Hebr`, by the alignment below with an exact match scoring 4 and a near match (an edit distance of 1, or 2 for words of 6 letters or more) scoring 2.
- A TAHOT Qere row whose `K=` note gives the Ketiv takes the Ketiv's split and glosses when the WLC word matches it at least as well as the Qere.
- No morph code comes from TAHOT, whose morphology is ETCBC's. A word OSHB does not pair would take TAHOT's split with no `morph`; with the locked sources there is none.

TCGNT:

- `strong` is the parser's, except where Byztxt's tag on the same form disagrees. Each chapter is aligned with Byztxt's words of that chapter, by the Greek search fold with only letters kept, `SearchText.normalize` with `Grek`. The scores are bible-api's: an exact form 4, a movable nu or sigma or an elided vowel 3, a spelling variant within a small edit distance 2, anything else never paired. A pair scoring 2 is trusted only when Byztxt never uses the word's exact form for a different Strong's id.
- On a trusted pair scoring 3 or 4, Byztxt's Strong's id is kept over the parser's. The eBible tags ignore accents and breathings, so `ἢ` "or" carries the article's G3588, relative `ὅ` the article's, and `τίς` and `τις` swap. On a pair scoring 2, the parser's id is kept. A word the parser left untagged takes Byztxt's.
- `morph` is the Robinson code of the paired Byztxt word, its first analysis where it has two. A word Byztxt does not pair has no `morph`. No morph code comes from TAGNT.
- `gloss` is TAGNT's contextual gloss when the chapter alignment pairs the word with a TAGNT word whose Strong's id, or whose lemma's id in TBESG or Strong's, is the word's. Otherwise it is TBESG's gloss of the id. Otherwise it is `NULL`.
- `lemma` is TBESG's, else Strong's.

The alignment is bible-api's `alignSequences`: the global pairing in order with the highest total score. It runs within `abs(n - m) + 128` of the diagonal, which gives byte-identical packages to the unbanded alignment for both editions and keeps a chapter's cost linear in its length.

The build prints a coverage table and refuses to write the package when `gloss` covers under 95 percent of the words, or `morph` under 99 percent for the WLC or 95 percent for the TCGNT, unless `--allow-gaps` is set. For the locked sources:

| | WLC | TCGNT |
|---|---|---|
| Words | 305,495 | 140,182 |
| With `strong` | 299,808 (98.14%) | 140,171 (99.99%) |
| With `morph` | 305,495 (100.00%) | 139,941 (99.83%) |
| With `gloss` | 304,960 (99.82%), all contextual | 140,163 (99.99%): 134,406 contextual, 5,757 from TBESG |
| With `parts` | 145,968 (47.78%) | 0 |
| Verses needing alignment by letters | 0 with OSHB, 170 with TAHOT | 2,321 with a word not paired exactly |
| Words matched to no source word | 0 with OSHB, 535 with TAHOT | 241, which have no `morph` |
| Ketiv words | 1,266 of OSHB's; 997 TAHOT Ketiv readings used | |
| Strong's filled in | 0 from OSHB, 1 from TAHOT | |
| Piece counts differ | 581 words where OSHB and TAHOT disagree, whose parts have no `gloss` | |
| Strong's disagreements | 3,429 with TAHOT, the parser's id kept | 2,158 with Byztxt: 2,156 on the same form, Byztxt's id kept; 2 fuzzy, the parser's kept |

A WLC word with no `strong` is a preposition with a pronoun suffix, such as `בּוֹ` "in it", which Strong's gives no entry. OSHB's lemma for it is the letter `b` or `l`, not a number. Its `parts` carry TAHOT's codes for both pieces.

The build is deterministic. Rows go in by verse id and position, and two builds with the same `--built-at` are byte-identical, as are their `.xz` files. It writes beside the destination and renames into place, with a 4096-byte page size, `VACUUM`, and rollback journal mode, as the edition package does.

### Validating words

`bible-pack validate <file>` on a words package runs these checks in order and exits 1 on the first failure.

1. `PRAGMA integrity_check`.
2. `meta`: `kind` is `words`, the format version, `version`, `built_at`, a known tagged `edition`, a 64-hex `edition_source_sha256`, and nonempty `attribution` and `sources` arrays.
3. Every `verse_id` decodes to a verse of the edition's scheme.
4. Positions run 1 to n in every verse.
5. Every `strong` is a stored id of the edition's language.
6. Every `parts` value decodes, and every part's `strong` is a stored id.
7. For the WLC, every `morph` and every part's `morph` follows the OSHB code grammar. The check reports the count of codes that do not and fails on any.
8. With `--lexicon <file>`, every `strong` has an entry in that lexicon.
9. The `.xz` beside the package, when present, decompresses to the package's bytes.
10. With `--against-source`, the edition is parsed again and every row's verse, position, and surface equal the parse's, and `edition_source_sha256` is the locked source's.

### Words schema

`WordsSchema.ddl` holds the schema. A test checks that this block matches it.

```sql
CREATE TABLE meta (
  key TEXT PRIMARY KEY NOT NULL,
  value TEXT NOT NULL
) WITHOUT ROWID;

INSERT INTO meta (key, value) VALUES ('format_version', '1');
INSERT INTO meta (key, value) VALUES ('format_minor', '0');
INSERT INTO meta (key, value) VALUES ('kind', 'words');

CREATE TABLE words (
  verse_id INTEGER NOT NULL,
  position INTEGER NOT NULL CHECK (position >= 1),
  surface TEXT NOT NULL,
  strong TEXT,
  morph TEXT,
  lemma TEXT,
  gloss TEXT,
  parts TEXT,
  PRIMARY KEY (verse_id, position)
) WITHOUT ROWID;
```

## Lexicon package

A lexicon package is one language's dictionary, one entry per Strong's id. Every words package in the language points into it, so it is downloaded once.

### Lexicon `meta`

The keys of a words package's `meta`, less `edition` and `edition_source_sha256`, plus `language`, the BCP 47 tag `grc` or `hbo`. `kind` is `lexicon`.

### `entries`

| Column | Meaning |
|---|---|
| `strong` | The Strong's id at Strong's level. The primary key. |
| `lemma` | The dictionary form. Never empty. |
| `transliteration` | The source's transliteration, as written. |
| `pronunciation` | Strong's own respelling, such as `log'-os` or `el-o-heem'`. |
| `part_of_speech` | The STEPBible morph summary code, as written: `G:N-M`, `N:N-M-P`, `H:N-M`, `A:V`. A stable code the app decodes, not a sentence. |
| `gloss` | A short English gloss. |
| `definition` | Strong's definition, with its etymology removed. |
| `occurrences` | How often the id occurs in the words package given with `--count-from`, or `NULL` when none was. |

Greek, from `tbesg` and `strongs`:

- `lemma`, `transliteration`, `part_of_speech`, and `gloss` from TBESG's lemma-level row of the id, the first row of its eStrong. A disambiguated gloss such as `to see: see` keeps the part before the colon.
- TBESG takes most entries from Abbott-Smith (1922), marked `(AS)` at the end of the meaning, which is public domain. It takes some from Middle Liddell, marked `(ML)`, which reached it from the Perseus Digital Library under CC BY-SA. No field of an `(ML)` row ships. The reader drops 2,303 such ids. For the 63 of them in Strong's range, the entry is Strong's alone, with no gloss or part of speech.
- `lemma` and `transliteration` from Strong's where TBESG has no shippable row, and `pronunciation` and `definition` from Strong's always.
- The definition takes `<strongs_derivation>` and `<strongs_def>` together, renders each `<strongsref>` as the lemma it names, and cuts the derivation's leading etymology clauses at their top-level semicolons, as bible-api does: θεός keeps "a deity, especially (with ὁ) the supreme Divinity", ἄνθρωπος drops "from ἀνήρ and ὤψ (the countenance; from ὀπτάνομαι)", and ἐγώ, which has no `<strongs_def>`, keeps its derivation.

Hebrew, from `tbesh` and `strongs`:

- `lemma`, `transliteration`, `part_of_speech`, and `gloss` from TBESH, at Strong's level: the plain eStrong row, else the number's first homonym row, so `H1254` takes `H1254a`, "to create". All 8,674 entries have a TBESH gloss and part of speech.
- TBESH's Meaning column is Online Bible's abridged BDB, which needs Online Bible's permission. The reader never parses it. TBESH's gloss and morph columns are Tyndale House's own.
- `pronunciation` and `definition` from Strong's Hebrew dictionary. The definition is the explanation note, completed from the exegesis note where the explanation opens inside a parenthesis the exegesis began. The `gloss` attribute of each entry holds TWOT numbers, which are copyrighted, so nothing reads it.

The entries are every id in Strong's dictionary, 5,523 Greek and 8,674 Hebrew, plus any id the words package uses that the sources define. `build-lexicon` prints how many ids the words package uses that the lexicon lacks and refuses to write it if any, unless `--allow-gaps`. For the locked sources the count is 0 for both.

### Validating a lexicon

1. `PRAGMA integrity_check`.
2. `meta`: `kind` is `lexicon`, the format version, `version`, `built_at`, `language` `grc` or `hbo`, and nonempty `attribution` and `sources`.
3. Every `strong` is a stored id of the language.
4. The ids' text order, the table's order, is their numeric order.
5. Every `lemma` is nonempty.
6. With `--words <file>`, every id that words package uses has an entry.
7. The `.xz`, when present, decompresses to the package's bytes.

### Lexicon schema

`LexiconSchema.ddl` holds the schema. A test checks that this block matches it.

```sql
CREATE TABLE meta (
  key TEXT PRIMARY KEY NOT NULL,
  value TEXT NOT NULL
) WITHOUT ROWID;

INSERT INTO meta (key, value) VALUES ('format_version', '1');
INSERT INTO meta (key, value) VALUES ('format_minor', '0');
INSERT INTO meta (key, value) VALUES ('kind', 'lexicon');

CREATE TABLE entries (
  strong TEXT PRIMARY KEY NOT NULL,
  lemma TEXT NOT NULL CHECK (lemma <> ''),
  transliteration TEXT,
  pronunciation TEXT,
  part_of_speech TEXT,
  gloss TEXT,
  definition TEXT,
  occurrences INTEGER CHECK (occurrences >= 0)
) WITHOUT ROWID;
```

### Attribution

A words or lexicon package's `attribution` lists the credit of exactly the sources in its `sources`: the edition's own attribution from `editions/<id>.json`, then each file set's `attribution` from the lock. The `oshb` set's is "Open Scriptures Hebrew Bible Project, github.com/openscriptures/morphhb (CC BY 4.0)". A package that ships a TBESG field adds "Abbott-Smith, A Manual Greek Lexicon of the New Testament (1922), public domain, via STEPBible TBESG" before STEPBible's credit. A package that ships a TBESH field adds "STEP Bible TBESH (Tyndale House Cambridge), CC BY 4.0, gloss and grammar fields only" before STEPBible's credit.

| Package | `sources` |
|---|---|
| `wlc-<v>.words` | `wlc`, `oshb`, `tahot`, `tbesh`, `strongs` |
| `tcgnt-<v>.words` | `tcgnt`, `byztxt`, `tagnt`, `tbesg`, `strongs` |
| `lexicon-greek-<v>.lexicon` | `tbesg`, `strongs` |
| `lexicon-hebrew-<v>.lexicon` | `tbesh`, `strongs` |

## Sources lock

`sources.lock.json` pins every input a package is built from. It is JSON with sorted keys, two-space indents, and a trailing newline: `{"sources": {<id>: <entry>}, "version": 1}`. An id is lowercase letters and digits. Every entry has these fields.

| Field | Holds |
|---|---|
| `format` | `usfm` or `usfx` for a publisher zip, `files` for a file set. |
| `file` | The zip's name in the sources directory. One plain `.zip` name: letters, digits, `.`, `_`, and `-`. |
| `url` | Where the source comes from. |
| `revision` | The upstream's date, `YYYY-MM-DD`. |
| `sha256` | What the lock pins. |
| `bytes` | The source's size. |
| `archive` | The archived copy, `<file stem>-<revision>-<first 8 hex of sha256>.zip` under the `source-archive` release of `tuxr/bible-data`. A file set whose license asks that it not be redistributed has no `archive` and says `"redistributable": false` instead. An entry has exactly one of the two, and a publisher zip always has an `archive`. |

### Publisher zips

A `usfm` or `usfx` entry pins a zip the publisher serves at an unversioned URL. `file` is the URL's last path component. `sha256` and `bytes` are the zip's. `revision` is the newest entry's modification date in UTC. `scriptureSha256` hashes only the scripture: the one `*_usfx.xml` entry, or for USFM each `.usfm` entry's path, a newline, then its bytes, in path order. A zip whose `sha256` changes and whose `scriptureSha256` does not was only re-zipped.

A text change always ships under a new package version. When a publisher revises a source, the relocked entry gets a new `revision`, `sha256`, and `archive`. The next release builds new packages from it, and every published package keeps its bytes. A zip whose `scriptureSha256` is unchanged gets a new entry too, but its packages hold the same text.

### File sets

A `files` entry pins plain files at one GitHub commit. Upstream serves no zip, so `bible-pack` builds one.

| Field | Holds |
|---|---|
| `url` | The commit, `https://github.com/<owner>/<repo>/tree/<sha>`. |
| `revision` | The commit's committer date. |
| `files` | One object per file, sorted by `name` in UTF-8 byte order: `name`, `url` (the raw file at that commit), `sha256`, and `bytes`. |
| `sha256` | The set hash: over the files in name order, each file's `name`, a newline, then its bytes. The same rule as the USFM scripture hash, so renaming a file changes it. |
| `bytes` | The total of the files' sizes. |
| `file` | `<id>.zip`. |
| `archiveSha256` | The SHA-256 of `<id>.zip`. |
| `license` | The license, such as `CC BY 4.0` or `Public domain`. |
| `attribution` | The credit a package built from the files must show, quoting the files' own header where they have one. |

A file set entry has no `scriptureSha256`, because the set hash already covers only the files. A file's `name` is its URL's last path component, percent-decoded, with spaces as underscores. It must be one plain name of letters, digits, `.`, `_`, and `-`.

`<id>.zip` holds each file under its `name`, stored without compression. Its entries are in name order, and each carries the revision at 00:00:00 UTC in both the DOS fields and the extended timestamp field. The zip's bytes are therefore a function of the files and the revision. `sources fetch` takes the archived zip if its SHA-256 is `archiveSha256` and its files hash to `sha256`. Otherwise it downloads each file, checks each `sha256`, and rebuilds the zip, which must hash to `archiveSha256`. A set with `"redistributable": false` is always rebuilt from its files. `archiveSha256` still pins the zip `bible-pack` builds in the sources directory.

The four STEPBible sets, `tahot`, `tagnt`, `tbesg`, and `tbesh`, are `"redistributable": false`. Their headers ask users to get the data from STEPBible and not to redistribute it. `byztxt` and `strongs` are public domain and keep their archives. `oshb` is CC BY 4.0, whose README asks only for credit, and keeps its archive.

### Licenses of the word sources

The WLC words take their morphology from OSHB, locked as `oshb` at `github.com/openscriptures/morphhb` commit `3d15126`. Its README and LICENSE.md license the lemma and morphology under CC BY 4.0 and ask that the credit go to the Open Scriptures Hebrew Bible Project. The WLC text itself is in the public domain. The eBible USFX's own OSHB tags fall under the same license; eBible's `copr.htm` inside `hboWLC_usfx.zip` still prints CC BY-SA 3.0. A package that ships the WLC's lemma or morphology credits the Open Scriptures Hebrew Bible Project under CC BY 4.0, which the `oshb` lock entry's attribution does.

What each word source may supply follows from its license:

| Source | License | Ships | Never ships |
|---|---|---|---|
| OSHB | CC BY 4.0, the WLC text public domain | Morphology and its pieces, Strong's ids where the parser has none | |
| TAHOT | CC BY 4.0, morphology from ETCBC under CC BY-NC | Glosses, the prefix and suffix split, Strong's ids | Its morphology column |
| TAGNT | CC BY 4.0, parsing from MorphGNT under CC BY-SA | Glosses, Strong's ids for matching | Its parsing |
| TBESG | CC BY 4.0, Abbott-Smith (1922) public domain | Lemma, transliteration, part of speech, gloss of `(AS)` and untagged rows | Any field of an `(ML)` row, Middle Liddell under CC BY-SA |
| TBESH | CC BY 4.0, Meaning from Online Bible's abridged BDB | Lemma, transliteration, part of speech, gloss | Its Meaning column |
| Byztxt | Public domain | Strong's ids and Robinson morphology | |
| Strong's XML | Public domain | Lemma, transliteration, pronunciation, definition | The Hebrew `gloss` attribute, which holds TWOT numbers |

## Compatibility

A reader supports a set of format versions. It opens a package only if `meta.format_version` is in that set.

- An additive change keeps the format version and raises `format_minor`. Additive means a reader that knows the format version can ignore the change. Examples are a new table, a new nullable column, a new `meta` key, and a new `RunStyle` bit.
- Any other change raises `format_version`. Examples are a new chapter item, a new block kind, a new chapter encoding, and a changed column.
- The manifest lists each package's `format_version` and `min_app_version`. The app hides a package whose `format_version` it does not support. `min_app_version` is the oldest app version that supports it.

## Manifest

`manifest.json` lists every published package version. The app's Library reads it to list the editions, words packages, and lexicons with their sizes. To install one, the app downloads the entry's `url`, decompresses it, and keeps the result only if its SHA-256 is the entry's `sha256`. `Manifest` decodes and checks the file, and `bible-pack manifest build` writes it. Like the sources lock, it is JSON with sorted keys, two-space indents, and a trailing newline, so one manifest has one byte form.

| Field | Holds |
|---|---|
| `manifest_version` | `1`. |
| `generated_at` | When the manifest was written, ISO 8601 in UTC. A release uses its tag's commit time. |
| `base_url` | An absolute `https` URL ending in `/`, `https://bible.dws-cloud.com/data/`. |
| `packages` | One entry per package version. |

Every entry has these fields.

| Field | Holds | From |
|---|---|---|
| `id` | `canon`, the edition id, `<edition>-words`, or `lexicon-<greek\|hebrew>`. | `meta` and `edition` |
| `kind` | `canon`, `edition`, `words`, or `lexicon`. | `meta.kind` |
| `version` | The package version. | `meta.version` |
| `format_version` | The package's format version. | `meta.format_version` |
| `min_app_version` | The oldest app version that opens the package, such as `1.0`. | `manifest/policy.json` |
| `file` | The package file name. See File names. | `kind`, `id`, and `version` |
| `url` | The download, `<file>.xz`, relative to `base_url`. | `file` |
| `size`, `sha256` | The package's size in bytes and SHA-256, lowercase hex. | The package file |
| `compressed_size`, `compressed_sha256` | The same for the download. | The `.xz` file |
| `released` | The UTC date of `meta.built_at`, `yyyy-mm-dd`. | `meta.built_at` |
| `attribution` | The credit lines the app shows, a nonempty array. | `edition.attribution`, `meta.attribution`, or the canon's `meta.versification_attribution` |

An entry carries its kind's fields at the same level.

| Kind | Fields | From |
|---|---|---|
| `edition` | `name`, `abbreviation`, `language`, `script`, `direction`, `versification`, `license`, `publisher`, and `source`: `{url, revision, sha256}` | The `edition` row |
| `words` | `edition`, `language` (`hbo` or `grc`), `edition_source_sha256`, and `sources` | `meta`. `language` is the tagged edition's. |
| `lexicon` | `language` (`grc` or `hbo`) and `sources` | `meta` |
| `canon` | None | |

The app installs a words package only beside the edition whose `source.sha256` is the words entry's `edition_source_sha256`, since a words file belongs to exactly the text it was aligned to.

The BSB entry of the 2026.10 build:

```json
{
  "abbreviation": "BSB",
  "attribution": [
    "Berean Standard Bible, Public Domain, bereanbible.com"
  ],
  "compressed_sha256": "256c670477356911c5c2243208983f6117bb40faed020e75ae049072910c908d",
  "compressed_size": 3249208,
  "direction": "ltr",
  "file": "bsb-2026.10.bible",
  "format_version": 1,
  "id": "bsb",
  "kind": "edition",
  "language": "en",
  "license": "Public domain",
  "min_app_version": "1.0",
  "name": "Berean Standard Bible",
  "publisher": "Bible Hub",
  "released": "2026-10-30",
  "script": "Latn",
  "sha256": "579b0cc761321417b1f50df869b03511997741804a27bb71e74890e3935934de",
  "size": 14184448,
  "source": {
    "revision": "2026-10-02",
    "sha256": "f0c56438eb89c98e8f62c5c00461e25cc35b098ad5b179bc350cede759ee5f87",
    "url": "https://bereanbible.com/bsb_usfm.zip"
  },
  "url": "bsb-2026.10.bible.xz",
  "versification": "eng",
  "version": "2026.10"
}
```

### Rules

- Every field but `min_app_version` comes from the package file: its `meta` and `edition` rows, its bytes, and its `.xz`. Nothing is typed by hand, so the manifest cannot disagree with the files. `manifest build` refuses a file whose name is not the one its `meta` gives.
- `min_app_version` comes from `manifest/policy.json`, `{"min_app_version": {<kind>: {<format version>: <app version>}}}`. An app version is one to three dot-separated numbers. `ManifestPolicy` parses it, and a package of a kind and format version the policy does not name is refused.
- Entries go by kind, canon first, then edition, words, and lexicon, then by id, then newest version first. Several versions of one id coexist. The app takes the first entry of an id whose `format_version` it supports and whose `min_app_version` is at most its own version.
- A published package never changes, and old versions stay published. `manifest build --merge <published manifest>` keeps every published entry whose file is not being built, and replaces the entry of a file that is, which must have the published `sha256`. A rebuilt file with other bytes is refused: the change ships under a new version.
- A reader ignores fields it does not know and skips an entry whose `kind` it does not know, so an older app keeps reading a newer manifest. `Manifest.unknownKinds` lists what was skipped.

### Validating a manifest

`bible-pack manifest validate <manifest.json>` runs these checks in order. It exits 1 on the first failure and names the check.

1. `schema`: every field the entry's kind requires, with its JSON type, and a `version` that parses.
2. `manifest_version` is 1, `generated_at` is an ISO 8601 UTC time, and `base_url` is an absolute `https` URL ending in `/`.
3. `ids`: each id is the one its kind gives, with a valid edition id or a lexicon language.
4. `files`: each `file` is the name its kind, id, and version give, and each `url` is `<file>.xz`.
5. `released` is a `yyyy-mm-dd` date, `size` and `compressed_size` are positive, every hash is 64 lowercase hex digits, `attribution` is nonempty, and `min_app_version` is an app version.
6. `unique`: one entry per id and version. `order`: the order above.
7. `format_version`: the newest version of each id has a format version from 1 to the kind's current one, `PackageFormat.version` or, for the canon, `CanonSchema.version`.

With `--dist <dir>` it then checks the files in that directory.

1. Every package in the directory is listed.
2. Each entry has both its package and its download in the directory, or neither. An entry with neither, such as an earlier release's, is skipped.
3. Each present file's size and SHA-256 are the entry's, for the package and then the download.
4. Each download decompresses to bytes with the entry's `sha256`.

### Delivery

A release publishes every package and download under `data/` in the R2 bucket `bible-data`, with `Cache-Control: public, max-age=31536000, immutable`, then `manifest.json` with `Cache-Control: public, max-age=300`. An object already at a package's key is skipped when its SHA-256 matches and fails the release when it does not. The same files, the manifest, and `SHA256SUMS` are attached to the release's GitHub release as the provenance archive. [docs/hosting.md](docs/hosting.md) sets up the bucket and its route.

## Change log

### Format version 1 (unreleased)

- First definition: edition package schema, chapter model, versification schemes `eng`, `heb`, and `grc`, and the canon package schema.
- Chapter encoding 1 (`binary`) is the shipped encoding, chosen on 2026-10-30 by the benchmark in `docs/benchmarks/chapter-codec-2026-10-30.md`. Encoding 0 (`json`) stays as the reference.
- `verses.text_search` holds folded search text where it differs from `text_plain`, and `verses_fts` indexes the `verses_search` view.
- `meta.absent_verses` lists the scheme verses an edition does not print.
- Parsing rules for USFM 3 and USFX sources, and the note caller rule for labels.
- `verses.text_search`, the `verses_search` view as the search index's content, the `SearchText` folding rules, the `meta.absent_verses` key, edition metadata files, and the `.xz` download.
- The sources lock, with file set entries for word and lexicon sources. A file set can be `"redistributable": false` with no archive.
- `meta.kind` in every package: `edition`, `words`, `lexicon`, and `canon`.
- The words package and the lexicon package, the `StrongID` stored form, and the alignment rules that build them.
- `meta.version` in every package, package versions `yyyy.mm.n` for a rebuild in the same month, the published canon name `canon-<version>.sqlite` with an `.xz`, and `manifest.json` with `manifest/policy.json`.
