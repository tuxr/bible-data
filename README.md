# bible-data

Scripture packages for the Bible app, and the toolchain that builds them.

The app reads one immutable SQLite package per edition. `bible-pack` builds those packages from publisher sources that are locked by URL and SHA-256. `BibleFormat` holds the format: canon tables, versification schemes and mappings, the chapter model and codec interface, and the package schema. The app's `BibleKit` links the same module, so the writer and the reader share one implementation.

The plan this repo serves lives in `tuxr/bible-ios` under `docs/`. Phase 0 there lists the steps for this repo. [FORMAT.md](FORMAT.md) is the format specification.

## Layout

| Path | Holds |
|---|---|
| `Sources/BibleFormat` | The shared format module. No dependencies beyond Foundation. |
| `Sources/BibleFormat/Resources/versification` | Verse counts per scheme and the mappings between schemes. |
| `Sources/bible-pack` | The macOS CLI. |
| `Tests` | Swift Testing suites for both targets. |
| `Tests/Goldens` | Parsed chapters from the real sources, compared on every test run. |
| `Tools` | Scripts that derive the verse counts from the publisher zips and the mappings from STEPBible's TVTMS; `lock-word-sources.sh`, which locks the word and lexicon file sets and skips any already in the lock; `release-build.sh`, which builds and checks a release; and `publish-r2.sh`, which uploads one. |
| `manifest/policy.json` | The oldest app version that opens each package kind at each format version, which `manifest build` copies into the manifest. |
| `docs/hosting.md` | The runbook for the R2 bucket, its credentials, and the route the app downloads from. |
| `editions` | One metadata file per edition, `<id>.json`: its names, language, script, versification, license, attribution, and locked source. |
| `sources.lock.json` | The locked sources: publisher zips and file sets. |
| `FORMAT.md` | The format specification, versioned. |

## Commands

```sh
swift build
swift test
swift run bible-pack --help
```

`bible-pack sources` manages the lock.

| Command | Does |
|---|---|
| `sources show` | Prints the lock. |
| `sources lock [id ...]` | Downloads each source, computes its hashes and revision, and rewrites the lock. A file set is rebuilt into `.sources/<id>.zip`. `--add <id>:<format>:<url>` adds a publisher zip, `usfm` or `usfx`. |
| `sources add-files <id> --repo <tree-url> --license <text> --attribution <text> [--not-redistributable] <raw-url> ...` | Adds a file set: plain files at one GitHub commit. `--repo` is `https://github.com/<owner>/<repo>/tree/<sha>`, and each raw URL must be `https://raw.githubusercontent.com/<owner>/<repo>/<sha>/<path>` at that commit. Writes `.sources/<id>.zip` and prints the archive name to upload. `--not-redistributable` locks no archive, for files whose license asks not to be redistributed. |
| `sources verify [id ...]` | Downloads each source and compares it to the lock. Exits 1 on any change. |
| `sources fetch [id ...]` | Puts the locked bytes in `.sources/`, from the archive first and the upstream second. A file set's upstream is its files, rebuilt into the zip. A set with no archive is always rebuilt from its files. Exits 1 on a hash mismatch. |

`bible-pack canon` builds and checks the canon package.

| Command | Does |
|---|---|
| `canon build [--out dist/canon.sqlite] [--version <version>] [--built-at <iso8601>]` | Writes the canon package and its `.xz` from the `BibleFormat` tables and prints each table's row count and both files' sizes and SHA-256. A published canon is named `canon-<version>.sqlite`. |
| `canon validate <path>` | Checks a canon package against the `BibleFormat` tables. Exits 1 on the first failure. |

`bible-pack parse` reads an edition's locked zip from `.sources/` and shows what the parsers make of it.

| Command | Does |
|---|---|
| `parse <edition>` | Prints the census: books, chapters, verses, absent verses, notes, words, and warnings. Exits 1 on any warning unless `--allow-warnings` is set. |
| `parse <edition> --book PSA [--chapter 23]` | Prints a book or one chapter, one line per item. `--json` prints the items as `JSONChapterCodec` writes them, then the notes. `--plain` prints each verse's plain text. |

The editions are `bsb`, `wlc`, and `tcgnt`. [FORMAT.md](FORMAT.md) lists the parsing rules.

`bible-pack build` and `bible-pack validate` make and check an edition package.

| Command | Does |
|---|---|
| `build <edition> [--out dist/] [--version <version>] [--built-at <iso8601>] [--encoding json\|binary]` | Parses the edition, refusing any warning, and writes `<id>-<version>.bible` and its `.xz` download. Prints each table's row count and both files' sizes and SHA-256. The version is `yyyy.mm`, or `yyyy.mm.n` for a rebuild in the same month, and defaults to the year and month of the build time, in UTC. |
| `validate <package> [--against-source]` | Checks integrity, the canon, every chapter's decoding and text round trip, verse numbers against the scheme, search text, the search index, notes, and the `.xz`. `--against-source` also parses the edition again and compares every chapter and row. Exits 1 on the first failure and names the check. |

```sh
swift run -c release bible-pack build bsb --out dist
swift run -c release bible-pack validate dist/bsb-2026.10.bible --against-source
```

`bible-pack build-words` and `bible-pack build-lexicon` make the word study packages, and `validate` checks them.

| Command | Does |
|---|---|
| `build-words <wlc\|tcgnt> [--out dist/] [--version <version>] [--built-at <iso8601>] [--allow-gaps]` | Parses the edition, aligns its words with the edition's word sources, prints the coverage table, and writes `<id>-<version>.words` and its `.xz`. Refuses a gloss coverage under 95 percent, a WLC morph coverage under 99 percent, or a TCGNT morph coverage under 95 percent, unless `--allow-gaps`. |
| `build-lexicon <greek\|hebrew> [--out dist/] [--version <version>] [--built-at <iso8601>] [--count-from <words file>] [--allow-gaps]` | Writes `lexicon-<language>-<version>.lexicon` and its `.xz`. With `--count-from`, fills `occurrences` and refuses the build when the words package uses an id the lexicon lacks, unless `--allow-gaps`. |
| `validate <words file> [--against-source] [--lexicon <lexicon file>]` | Checks verse ids, positions, Strong's ids, parts, and for the WLC that every morph code follows the OSHB code grammar. `--lexicon` checks every Strong's id has an entry. `--against-source` parses the edition again and compares every surface and position. |
| `validate <lexicon file> [--words <words file>]` | Checks ids, their order, and lemmas. `--words` checks every id that words package uses has an entry. |

`validate` reads a file's `meta.kind` and runs that kind's checks, so it takes edition, words, lexicon, and canon packages alike.

```sh
swift run -c release bible-pack build-words tcgnt --out dist
swift run -c release bible-pack build-lexicon greek --out dist --count-from dist/tcgnt-2026.10.words
swift run -c release bible-pack validate dist/tcgnt-2026.10.words --against-source --lexicon dist/lexicon-greek-2026.10.lexicon
swift run -c release bible-pack validate dist/lexicon-greek-2026.10.lexicon --words dist/tcgnt-2026.10.words
```

[FORMAT.md](FORMAT.md#words-package) gives the alignment rules, the coverage of each package, and what each word source's license lets a package ship.

`bible-pack manifest` writes and checks `manifest.json`, the list the app's Library downloads from.

| Command | Does |
|---|---|
| `manifest build [--dist dist] [--out <dist>/manifest.json] [--base-url <url>] [--generated-at <iso8601>] [--merge <manifest path or https URL>] [--policy manifest/policy.json]` | Opens every `.bible`, `.words`, `.lexicon`, and canon `.sqlite` package in the directory with the `.xz` beside it, and writes one entry per package from its own `meta` and `edition` rows and both files' sizes and SHA-256. Refuses a file whose name is not the one its `meta` gives. `--merge` keeps every entry of a published manifest whose file is not in the directory, and refuses a rebuilt file whose bytes differ from the published entry. A 404 merges nothing. |
| `manifest validate <manifest.json> [--dist <dir>]` | Checks the fields each kind requires, ids, file names and relative urls, dates, sizes, hashes, attribution, `min_app_version`, one entry per id and version, the order, and a supported format for the newest version of each id. `--dist` also checks that every package in the directory is listed, and that every entry whose files are there matches their sizes and hashes and decompresses to its SHA-256. Exits 1 on the first failure and names the check. |

```sh
swift run -c release bible-pack manifest build --dist dist
swift run -c release bible-pack manifest validate dist/manifest.json --dist dist
```

## Releases

A release is a tag. Pushing `v<version>` runs `.github/workflows/release.yml`, which builds the canon and every package at that version, stamped with the tag's commit time, validates each against its source and the others, merges the published manifest so earlier versions stay listed, and checks the result. It then attaches every package, download, `manifest.json`, and `SHA256SUMS` to a GitHub release of the tag, the provenance archive, and, once `R2_ENABLED` is set, uploads them to R2 with the manifest last. The first release of a month is `v2026.10`; a second in the same month is `v2026.10.1`, then `v2026.10.2`, since a published package never changes. Building the same tag again gives the same bytes, so a failed release can rerun from the workflow's Run workflow button with the tag. `Tools/release-build.sh <version> <built-at>` runs the same build locally into `dist/`. [docs/hosting.md](docs/hosting.md) sets up the bucket.

```sh
git tag v2026.10 && git push --tags
```

## Tests

`swift test` runs every suite. The golden, census, package build, and words build suites need the locked sources, so run `swift run bible-pack sources fetch` first. Without the zips, those suites are skipped.

`Tests/Goldens/<edition>/<BOOK>-<chapter>.json` holds a chapter's items, notes, plain text, and word tags, one element per line. A golden test parses the chapter again and fails with the first differing line. After a parser change that is meant to change the output, rewrite the goldens and review the diff:

```sh
UPDATE_GOLDENS=1 swift test --filter GoldenTests
git diff Tests/Goldens
```

## Sources

Publishers serve only the latest revision at an unversioned URL. The lock pins each adopted zip by SHA-256, records the publisher's revision date and a hash of the scripture inside the zip, and names an archived copy of exactly those bytes under the `source-archive` GitHub release. A zip whose bytes change but whose scripture hash does not was only re-zipped.

Word and lexicon sources are plain files in Git repositories. The lock pins each set of them to a commit, by each file's SHA-256 and a hash over the whole set, and `bible-pack` packs them into a deterministic `<id>.zip`. The release archives that zip for `byztxt`, `strongs`, and `oshb`. The four STEPBible sets ask not to be redistributed, so their entries say `"redistributable": false` and `sources fetch` rebuilds them from STEPBible's own files. [FORMAT.md](FORMAT.md#sources-lock) defines both kinds of entry.

| Id | Source | Format |
|---|---|---|
| `bsb` | Berean Standard Bible, from bereanbible.com | USFM 3 |
| `wlc` | Westminster Leningrad Codex, from eBible | USFX |
| `tcgnt` | Text-Critical Greek New Testament, from eBible | USFX |
| `tahot` | STEPBible TAHOT, the tagged Hebrew OT, in 4 files | files, CC BY 4.0, not redistributed |
| `tagnt` | STEPBible TAGNT, the tagged Greek NT, in 2 files | files, CC BY 4.0, not redistributed |
| `tbesg` | STEPBible TBESG, the brief Greek lexicon | files, CC BY 4.0, not redistributed |
| `tbesh` | STEPBible TBESH, the brief Hebrew lexicon | files, CC BY 4.0, not redistributed |
| `byztxt` | Robinson-Pierpont Byzantine Textform 2018, 27 CSV books with Strong's numbers and parsing | files, public domain |
| `strongs` | Strong's Greek and Hebrew dictionaries in XML, from Open Scriptures | files, public domain |
| `oshb` | Open Scriptures Hebrew Bible, the WLC's 39 books in OSIS with lemma and morphology on every word | files, CC BY 4.0 |

To archive a new zip or file set, upload it under the name at the end of its `archive` URL: `gh release upload source-archive <dir>/<archive name> --repo tuxr/bible-data`.

## Versification

Three schemes exist in format version 1: `eng` (KJV tradition, the canonical scheme for anchors), `heb` (Masoretic), and `grc` (Greek New Testament). Verse counts were derived from the KJV, WLC, and TCGNT zips with `Tools/derive-versification.py`. The `heb` to `eng` mapping is derived from STEPBible's TVTMS (CC BY 4.0) with `Tools/derive-heb-eng-mapping.py`, and tests prove every mapping round-trips.

## License

MIT. Scripture texts carry their publishers' licenses, recorded per edition in each package.
