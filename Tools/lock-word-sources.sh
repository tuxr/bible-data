#!/bin/sh
# Adds the word and lexicon file sets to sources.lock.json, as phase 0 step 5 first locked them.
# Each add-files refuses an id that is already locked; relock those with `bible-pack sources lock <id>`.
set -eu

pack() { swift run -c release bible-pack "$@"; }

STEP_SHA=be4191f0082aeedddb0eff0c02c966292b2bd641
STEP=https://raw.githubusercontent.com/STEPBible/STEPBible-Data/$STEP_SHA
AMALGAMATED=$STEP/Translators%20Amalgamated%20OT%2BNT
BYZ_SHA=27a45ff1b7be6c17ccbfeac414f3f55732ae8e28
STRONGS_SHA=0acd2f251c2d35ff8db2dece4e0593979d3ac223
STEP_CREDIT="Data created by www.STEPBible.org based on work at Tyndale House Cambridge (CC BY 4.0)."

pack sources add-files tahot \
  --repo https://github.com/STEPBible/STEPBible-Data/tree/$STEP_SHA \
  --license "CC BY 4.0" \
  --attribution "TAHOT - Translators Amalgamated Hebrew OT - STEPBible.org CC BY. $STEP_CREDIT" \
  "$AMALGAMATED/TAHOT%20Gen-Deu%20-%20Translators%20Amalgamated%20Hebrew%20OT%20-%20STEPBible.org%20CC%20BY.txt" \
  "$AMALGAMATED/TAHOT%20Jos-Est%20-%20Translators%20Amalgamated%20Hebrew%20OT%20-%20STEPBible.org%20CC%20BY.txt" \
  "$AMALGAMATED/TAHOT%20Job-Sng%20-%20Translators%20Amalgamated%20Hebrew%20OT%20-%20STEPBible.org%20CC%20BY.txt" \
  "$AMALGAMATED/TAHOT%20Isa-Mal%20-%20Translators%20Amalgamated%20Hebrew%20OT%20-%20STEPBible.org%20CC%20BY.txt"

pack sources add-files tagnt \
  --repo https://github.com/STEPBible/STEPBible-Data/tree/$STEP_SHA \
  --license "CC BY 4.0" \
  --attribution "TAGNT - Translators Amalgamated Greek NT - STEPBible.org CC BY 4.0. $STEP_CREDIT" \
  "$AMALGAMATED/TAGNT%20Mat-Jhn%20-%20Translators%20Amalgamated%20Greek%20NT%20-%20STEPBible.org%20CC-BY.txt" \
  "$AMALGAMATED/TAGNT%20Act-Rev%20-%20Translators%20Amalgamated%20Greek%20NT%20-%20STEPBible.org%20CC-BY.txt"

pack sources add-files tbesg \
  --repo https://github.com/STEPBible/STEPBible-Data/tree/$STEP_SHA \
  --license "CC BY 4.0" \
  --attribution "TBESG - Translators Brief lexicon of Extended Strongs for Greek - STEPBible.org CC BY. $STEP_CREDIT" \
  "$STEP/Lexicons/TBESG%20-%20Translators%20Brief%20lexicon%20of%20Extended%20Strongs%20for%20Greek%20-%20STEPBible.org%20CC%20BY.txt"

pack sources add-files tbesh \
  --repo https://github.com/STEPBible/STEPBible-Data/tree/$STEP_SHA \
  --license "CC BY 4.0" \
  --attribution "TBESH - Translators Brief lexicon of Extended Strongs for Hebrew - STEPBible.org CC BY. $STEP_CREDIT" \
  "$STEP/Lexicons/TBESH%20-%20Translators%20Brief%20lexicon%20of%20Extended%20Strongs%20for%20Hebrew%20-%20STEPBible.org%20CC%20BY.txt"

BYZ=https://raw.githubusercontent.com/byztxt/byzantine-majority-text/$BYZ_SHA/csv-unicode/strongs/with-parsing
set --
for book in MAT MAR LUK JOH ACT ROM 1CO 2CO GAL EPH PHP COL 1TH 2TH 1TI 2TI TIT PHM HEB JAM 1PE 2PE 1JO 2JO 3JO JUD REV; do
  set -- "$@" "$BYZ/$book.csv"
done
pack sources add-files byztxt \
  --repo https://github.com/byztxt/byzantine-majority-text/tree/$BYZ_SHA \
  --license "Public domain" \
  --attribution "Robinson-Pierpont Byzantine Textform 2018, with Strong's numbers and parsing, from github.com/byztxt/byzantine-majority-text." \
  "$@"

STRONGS=https://raw.githubusercontent.com/openscriptures/strongs/$STRONGS_SHA
pack sources add-files strongs \
  --repo https://github.com/openscriptures/strongs/tree/$STRONGS_SHA \
  --license "Public domain" \
  --attribution "Strong's Exhaustive Concordance dictionaries by James Strong (1890), XML by Open Scriptures, github.com/openscriptures/strongs." \
  "$STRONGS/greek/StrongsGreekDictionaryXML_1.4/strongsgreek.xml" \
  "$STRONGS/hebrew/StrongHebrewG.xml"
