#!/bin/bash
# Compares every locked source with its publisher. When one changed: relocks it, diffs the old and new text,
# rewrites the goldens, runs the tests and a full release build, archives the new zip, and opens or updates the
# pull request on source-watch/<yyyy-mm-dd>. With nothing changed it exits 0 and touches nothing.
# Usage: Tools/source-watch.sh
#   DRY_RUN=1 does the local work and prints each commit, push, upload, and pull request instead of making it.
#   GH_REPO is the repository (tuxr/bible-data), SOURCE_WATCH_BASE the base branch (main), and SOURCE_WATCH_OUT
#   where the diffs and logs go (.build/source-watch).
# Exits 1 when a check failed, after opening the pull request as a draft that says which.
set -euo pipefail

cd "$(dirname "$0")/.."
dry_run=${DRY_RUN:-0}
repo=${GH_REPO:-tuxr/bible-data}
base=${SOURCE_WATCH_BASE:-main}
out=${SOURCE_WATCH_OUT:-.build/source-watch}
day=$(date -u +%F)
branch="source-watch/$day"
budget=60000

effect() {
  if [[ "$dry_run" == 1 ]]; then
    printf 'DRY_RUN would run:'
    printf ' %q' "$@"
    echo
  else
    "$@"
  fi
}
pack() { .build/release/bible-pack "$@"; }
locked() { jq -r --arg id "$1" ".sources[\$id].$2 // empty" "$out/locked.json"; }
relocked() { jq -r --arg id "$1" ".sources[\$id].$2 // empty" sources.lock.json; }
chars() { LC_ALL=en_US.UTF-8 wc -m < "$1" | tr -d ' '; }

if [[ "$dry_run" != 1 && -n "$(git status --porcelain)" ]]; then
  echo "the working tree has changes; commit them first, or set DRY_RUN=1" >&2
  exit 1
fi

echo "== compile bible-pack"
swift build -c release --product bible-pack
echo "== fetch the locked sources"
pack sources fetch
rm -rf "$out"
mkdir -p "$out/upload"
cp sources.lock.json "$out/locked.json"

echo "== verify"
set +e
pack sources verify | tee "$out/verify.txt"
status=${PIPESTATUS[0]}
set -e
case $status in
  0) echo "every source matches the lock"; exit 0 ;;
  2) ;;
  *) echo "sources verify failed" >&2; exit 1 ;;
esac
ids=()
while read -r id _; do ids+=("$id"); done < <(grep 'changed from' "$out/verify.txt")

echo "== relock ${ids[*]}"
pack sources lock "${ids[@]}"

echo "== diff"
revisions=()
for id in "${ids[@]}"; do
  revisions+=("$(relocked "$id" revision)")
  [[ -f "editions/$id.json" ]] || continue
  old=".sources/archive/$(basename "$(locked "$id" archive)")"
  new=".sources/$(relocked "$id" file)"
  for format in markdown json; do
    set +e
    pack sources diff "$id" --from "$old" --to "$new" --format "$format" > "$out/$id.$format"
    status=$?
    set -e
    if [[ $status != 0 && $status != 2 ]]; then echo "sources diff $id failed" >&2; exit 1; fi
  done
  head -1 "$out/$id.markdown" | tr -d '`'
done

checks=()
failed=0
check() {
  local name=$1 log="$out/$2.log"
  shift 2
  echo "== $name"
  if "$@" > "$log" 2>&1; then
    checks+=("- $name: passed.")
  else
    failed=1
    checks+=("- $name: **failed**. The end of its log:" "" '```' "$(tail -20 "$log")" '```')
  fi
  tail -3 "$log"
}
# The goldens track the locked text, so a text change rewrites them and the diff below shows which chapters moved.
check "Rewrite the goldens from the new text" goldens env UPDATE_GOLDENS=1 swift test --filter GoldenTests
check "swift test" test swift test
check "Release build of every package, validated against its source" release \
  env RELEASE_MERGE= Tools/release-build.sh "$(date -u +%Y.%m)" "${day}T00:00:00Z" "$out/dist"
goldens=$(git status --porcelain -- Tests/Goldens | awk '{print $2}')

echo "== archive and attach"
gh release view source-watch --repo "$repo" > /dev/null 2>&1 \
  || effect gh release create source-watch --repo "$repo" --prerelease --title "Source watch diffs" \
    --notes "The JSON verse diffs of the source watch pull requests. Packages are never published here."
published=$(gh release view source-archive --repo "$repo" --json assets -q '.assets[].name')
sections=()
for id in "${ids[@]}"; do
  file=$(relocked "$id" file)
  archive=$(relocked "$id" archive)
  section="## $id"$'\n\n'"Locked $(locked "$id" revision) (\`$(locked "$id" sha256 | cut -c1-8)\`); the publisher now serves $(relocked "$id" revision) (\`$(relocked "$id" sha256 | cut -c1-8)\`)."
  if [[ -n "$archive" ]]; then
    name=$(basename "$archive")
    want=$(jq -r --arg id "$id" '.sources[$id] | .archiveSha256 // .sha256' sources.lock.json)
    have=$(shasum -a 256 ".sources/$file" | cut -d' ' -f1)
    [[ "$have" == "$want" ]] || { echo ".sources/$file is not the relocked $id" >&2; exit 1; }
    cp ".sources/$file" "$out/upload/$name"
    if grep -qxF "$name" <<< "$published"; then
      gh release download source-archive --repo "$repo" --pattern "$name" --output "$out/upload/published-$name" --clobber
      [[ "$(shasum -a 256 "$out/upload/published-$name" | cut -d' ' -f1)" == "$want" ]] \
        || { echo "source-archive already has a different $name; an archive is never replaced" >&2; exit 1; }
      echo "$name is already in source-archive"
    else
      effect gh release upload source-archive "$out/upload/$name" --repo "$repo"
    fi
    section+=" The new zip is archived as [\`$name\`]($archive)."
  fi
  if [[ -f "$out/$id.json" ]]; then
    json="$id-$(locked "$id" sha256 | cut -c1-8)-$(relocked "$id" sha256 | cut -c1-8).diff.json"
    cp "$out/$id.json" "$out/upload/$json"
    effect gh release upload source-watch "$out/upload/$json" --repo "$repo" --clobber
    section+=" The [JSON diff](https://github.com/$repo/releases/download/source-watch/$json) lists every change."
  else
    section+=" It is not an edition, so there is no verse diff: $(grep "^$id " "$out/verify.txt" | sed 's/  */ /g')."
  fi
  sections+=("$section")
done

ci="This branch was pushed with \`SOURCE_WATCH_TOKEN\`, so CI runs on it too."
[[ -n "${SOURCE_WATCH_TOKEN:-}" ]] || ci="This branch was pushed with \`GITHUB_TOKEN\`, which starts no CI run, so the checks above are the whole verification. Add a \`SOURCE_WATCH_TOKEN\` secret to have CI run on watch branches."
golden_note="No golden changed."
[[ -z "$goldens" ]] || golden_note="Rewritten goldens, which track the locked text and are part of this branch: $(echo "$goldens" | tr '\n' ' ')"
title="chore(sources): $(IFS=,; echo "${ids[*]}" | sed 's/,/, /g') revised $(printf '%s\n' "${revisions[@]}" | sort -u | paste -sd, - | sed 's/,/, /g')"

for limit in 200 100 50 20 5 0; do
  body="$out/body.md"
  {
    echo "\`sources verify\` found new publisher revisions on $day, and this pull request relocks them. Read each diff, then merge and tag \`vYYYY.MM[.n]\` to build new packages. A published package never changes."
    echo
    echo '```'
    cat "$out/verify.txt"
    echo '```'
    for index in "${!ids[@]}"; do
      id=${ids[$index]}
      echo
      echo "${sections[$index]}"
      if [[ -f "editions/$id.json" ]]; then
        echo
        pack sources diff "$id" --from ".sources/archive/$(basename "$(locked "$id" archive)")" --to ".sources/$(relocked "$id" file)" \
          --format markdown --limit "$limit" || [[ $? == 2 ]]
      fi
    done
    echo
    echo "## Checks"
    echo
    printf '%s\n' "${checks[@]}"
    echo
    echo "$golden_note"
    echo
    echo "$ci"
  } > "$body"
  [[ $(chars "$body") -le $budget ]] && break
done
echo "== pull request: $title ($(chars "$body") characters, at most $limit verses of each kind)"

effect git switch -C "$branch"
effect git add sources.lock.json Tests/Goldens
effect git -c user.name="github-actions[bot]" -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
  commit -m "$title"
# The watch owns its branches: a rerun on the same day rebuilds this one from the base and replaces it.
effect git push --force origin "$branch"
pr=$(gh pr list --repo "$repo" --head "$branch" --state open --json number -q '.[0].number // empty')
draft=()
[[ $failed == 0 ]] || draft=(--draft)
if [[ -n "$pr" ]]; then
  effect gh pr edit "$pr" --repo "$repo" --title "$title" --body-file "$body"
  # gh refuses to mark a pull request ready or draft when it already is one.
  if [[ $failed == 0 ]]; then effect gh pr ready "$pr" --repo "$repo" || true; else effect gh pr ready "$pr" --repo "$repo" --undo || true; fi
else
  effect gh pr create --repo "$repo" --base "$base" --head "$branch" --title "$title" --body-file "$body" ${draft[@]+"${draft[@]}"}
fi
for old in $(gh pr list --repo "$repo" --state open --json number,headRefName \
  -q ".[] | select(.headRefName | startswith(\"source-watch/\")) | select(.headRefName != \"$branch\") | .number"); do
  effect gh pr close "$old" --repo "$repo" --comment "Superseded by the source watch of $day, which relocks from $base again."
done
exit $failed
