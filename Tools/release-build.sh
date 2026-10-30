#!/bin/bash
# Builds, validates, and lists every package of a release into a fresh directory, as the release workflow does.
# Usage: Tools/release-build.sh <version> <built-at> [dist]
#   Tools/release-build.sh 2026.10 2026-10-30T00:00:00Z
# RELEASE_BASE_URL sets the manifest's base_url, and the published manifest at <base_url>manifest.json is merged
# so earlier versions stay listed. RELEASE_MERGE overrides what is merged; set it empty to merge nothing.
set -euo pipefail

version=${1:?usage: Tools/release-build.sh <version> <built-at> [dist]}
built_at=${2:?usage: Tools/release-build.sh <version> <built-at> [dist]}
dist=${3:-dist}
base_url=${RELEASE_BASE_URL:-https://bible.dws-cloud.com/data/}
merge=${RELEASE_MERGE-${base_url}manifest.json}

cd "$(dirname "$0")/.."
timings=()
step() {
  local name=$1 start=$SECONDS
  shift
  echo "== $name"
  "$@"
  timings+=("$(printf '%5ds  %s' $((SECONDS - start)) "$name")")
}

pack() { .build/release/bible-pack "$@"; }
stamp=(--version "$version" --built-at "$built_at")

step "compile bible-pack" swift build -c release --product bible-pack
step "fetch sources" pack sources fetch
rm -rf "$dist"
mkdir -p "$dist"

canon="$dist/canon-$version.sqlite"
step "build canon" pack canon build --out "$canon" "${stamp[@]}"
step "validate canon" pack canon validate "$canon"
for edition in bsb wlc tcgnt; do
  step "build $edition" pack build "$edition" --out "$dist" "${stamp[@]}"
  step "validate $edition" pack validate "$dist/$edition-$version.bible" --against-source
done
step "build wlc words" pack build-words wlc --out "$dist" "${stamp[@]}"
step "build tcgnt words" pack build-words tcgnt --out "$dist" "${stamp[@]}"
step "build hebrew lexicon" pack build-lexicon hebrew --out "$dist" "${stamp[@]}" --count-from "$dist/wlc-$version.words"
step "build greek lexicon" pack build-lexicon greek --out "$dist" "${stamp[@]}" --count-from "$dist/tcgnt-$version.words"
step "validate wlc words" pack validate "$dist/wlc-$version.words" --against-source --lexicon "$dist/lexicon-hebrew-$version.lexicon"
step "validate tcgnt words" pack validate "$dist/tcgnt-$version.words" --against-source --lexicon "$dist/lexicon-greek-$version.lexicon"
step "validate hebrew lexicon" pack validate "$dist/lexicon-hebrew-$version.lexicon" --words "$dist/wlc-$version.words"
step "validate greek lexicon" pack validate "$dist/lexicon-greek-$version.lexicon" --words "$dist/tcgnt-$version.words"

step "build manifest" pack manifest build --dist "$dist" --base-url "$base_url" --generated-at "$built_at" ${merge:+--merge "$merge"}
step "validate manifest" pack manifest validate "$dist/manifest.json" --dist "$dist"
sums=$(cd "$dist" && shasum -a 256 -- *)
printf '%s\n' "$sums" > "$dist/SHA256SUMS"

echo "== timings"
printf '%s\n' "${timings[@]}"
