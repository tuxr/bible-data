#!/bin/bash
# Uploads a release directory to the R2 bucket under data/, as the release workflow's publish job does.
# Usage: Tools/publish-r2.sh <dist>
# Needs the AWS CLI and R2_ACCOUNT_ID, AWS_ACCESS_KEY_ID, and AWS_SECRET_ACCESS_KEY (an R2 API token's S3 credentials).
# A published package never changes: an object already at its key is skipped when its sha256 matches and fails
# the run when it does not. manifest.json goes last, so it never lists a file that is not yet in the bucket.
set -euo pipefail

dist=${1:?usage: Tools/publish-r2.sh <dist>}
: "${R2_ACCOUNT_ID:?set R2_ACCOUNT_ID}" "${AWS_ACCESS_KEY_ID:?set AWS_ACCESS_KEY_ID}" "${AWS_SECRET_ACCESS_KEY:?set AWS_SECRET_ACCESS_KEY}"
bucket=${R2_BUCKET:-bible-data}
prefix=${R2_PREFIX:-data/}
endpoint=${R2_ENDPOINT:-https://$R2_ACCOUNT_ID.r2.cloudflarestorage.com}
export AWS_DEFAULT_REGION=auto
[ -f "$dist/manifest.json" ] || { echo "error: $dist has no manifest.json" >&2; exit 1; }

s3() { aws s3api --endpoint-url "$endpoint" "$@"; }
sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }
content_type() {
  case $1 in
    *.xz) echo application/x-xz ;;
    *.json) echo application/json ;;
    *) echo application/vnd.sqlite3 ;;
  esac
}
put() {
  local path=$1 key=$2 cache=$3
  s3 put-object --bucket "$bucket" --key "$key" --body "$path" --content-type "$(content_type "$path")" \
    --cache-control "$cache" --metadata "sha256=$(sha256 "$path")" > /dev/null
  echo "put   $key"
}

errors=$(mktemp)
trap 'rm -f "$errors"' EXIT
# SHA256SUMS belongs to the GitHub release; every release writes one under the same name, so it is not uploaded.
for path in "$dist"/*; do
  name=$(basename "$path")
  case $name in manifest.json | SHA256SUMS) continue ;; esac
  key="$prefix$name"
  sha=$(sha256 "$path")
  if published=$(s3 head-object --bucket "$bucket" --key "$key" --query 'Metadata.sha256' --output text 2> "$errors"); then
    if [ "$published" = "$sha" ]; then
      echo "skip  $key: already published with sha256 $sha"
      continue
    fi
    echo "error: $key is published with sha256 $published, not $sha; a published package never changes" >&2
    exit 1
  elif ! grep -q '(404)' "$errors"; then
    cat "$errors" >&2
    exit 1
  fi
  put "$path" "$key" "public, max-age=31536000, immutable"
done
put "$dist/manifest.json" "${prefix}manifest.json" "public, max-age=300"
