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
| `Tools` | Scripts that derive the verse counts from the publisher zips and the mappings from STEPBible's TVTMS. |
| `sources.lock.json` | The locked publisher sources. |
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
| `sources lock [id ...]` | Downloads each source, computes its hashes and revision, and rewrites the lock. `--add <id>:<format>:<url>` adds a source. |
| `sources verify [id ...]` | Downloads each source and compares it to the lock. Exits 1 on any change. |
| `sources fetch [id ...]` | Puts the locked bytes in `.sources/`, from the archive first and the publisher second. Exits 1 on a hash mismatch. |

`bible-pack canon` builds and checks the canon package.

| Command | Does |
|---|---|
| `canon build [--out dist/canon.sqlite] [--built-at <iso8601>]` | Writes `canon.sqlite` from the `BibleFormat` tables and prints each table's row count, the file size, and its SHA-256. |
| `canon validate <path>` | Checks a canon package against the `BibleFormat` tables. Exits 1 on the first failure. |

`build`, `validate`, and `manifest` take their arguments and stop. Phase 0 steps 4 and 6 implement them.

## Sources

Publishers serve only the latest revision at an unversioned URL. The lock pins each adopted zip by SHA-256, records the publisher's revision date and a hash of the scripture inside the zip, and names an archived copy of exactly those bytes under the `source-archive` GitHub release. A zip whose bytes change but whose scripture hash does not was only re-zipped.

| Id | Source | Format |
|---|---|---|
| `bsb` | Berean Standard Bible, from bereanbible.com | USFM 3 |
| `wlc` | Westminster Leningrad Codex, from eBible | USFX |
| `tcgnt` | Text-Critical Greek New Testament, from eBible | USFX |

## Versification

Three schemes exist in format version 1: `eng` (KJV tradition, the canonical scheme for anchors), `heb` (Masoretic), and `grc` (Greek New Testament). Verse counts were derived from the KJV, WLC, and TCGNT zips with `Tools/derive-versification.py`. The `heb` to `eng` mapping is derived from STEPBible's TVTMS (CC BY 4.0) with `Tools/derive-heb-eng-mapping.py`, and tests prove every mapping round-trips.

## License

MIT. Scripture texts carry their publishers' licenses, recorded per edition in each package.
