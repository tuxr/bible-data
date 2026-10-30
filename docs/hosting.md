# Hosting

The app downloads packages and `manifest.json` from a Cloudflare R2 bucket. The release workflow, `.github/workflows/release.yml`, uploads them there in its `publish` job, which runs only when the repository variable `R2_ENABLED` is `true`. Until then a release still builds, validates, and attaches every file to its GitHub release. These steps set up the bucket, its credentials, and the route.

## 1. Create the bucket

In the Cloudflare dashboard, open R2 and create a bucket named `bible-data` with automatic location. Or, with Wrangler logged in:

```sh
npx wrangler r2 bucket create bible-data
```

Leave public access through the `r2.dev` URL off. Step 4 picks the route the app uses.

## 2. Create the upload credentials

In R2, open Manage API tokens and create an account API token:

- Permission: Object Read & Write.
- Buckets: apply to `bible-data` only.
- TTL: forever, or a date you will rotate it by.

The page shows an Access Key ID and a Secret Access Key once. Copy both. The account ID is on the R2 overview page.

The publish job uses these S3 credentials with the AWS CLI rather than Wrangler. A package must never be overwritten, so before each upload the job asks for the object's stored SHA-256: it skips a key that already holds the same bytes and fails on one that holds different bytes. The S3 API's `HeadObject` returns that hash from the object's metadata. Wrangler's `r2 object` commands have no head request and set no custom metadata, so the same check through Wrangler would download every object.

## 3. Add the secrets and the variable

In `tuxr/bible-data`, Settings, Secrets and variables, Actions:

| Name | Kind | Value |
|---|---|---|
| `CLOUDFLARE_ACCOUNT_ID` | Secret | The account ID. |
| `R2_ACCESS_KEY_ID` | Secret | The token's Access Key ID. |
| `R2_SECRET_ACCESS_KEY` | Secret | The token's Secret Access Key. |
| `R2_ENABLED` | Variable | `true`. |
| `DATA_BASE_URL` | Variable, optional | The manifest's `base_url`, ending in `/`, if it is not `https://bible.dws-cloud.com/data/`. See step 4. |

```sh
gh secret set CLOUDFLARE_ACCOUNT_ID --repo tuxr/bible-data
gh secret set R2_ACCESS_KEY_ID --repo tuxr/bible-data
gh secret set R2_SECRET_ACCESS_KEY --repo tuxr/bible-data
gh variable set R2_ENABLED --body true --repo tuxr/bible-data
```

## 4. Route the downloads

The bucket holds every file under `data/`, such as `data/manifest.json` and `data/bsb-2026.10.bible.xz`. The plan serves them at `bible.dws-cloud.com/data/`, the origin of the web reader, whose Worker lives in `tuxr/bible-web`. An R2 custom domain is a whole hostname, so there are two ways to serve them.

**Option A: an R2 custom domain.** In the bucket's settings, connect a custom domain such as `bible-data.dws-cloud.com`, and set `DATA_BASE_URL` to `https://bible-data.dws-cloud.com/data/`. Cloudflare serves each object with the `Cache-Control` the upload stored, caches it at the edge, and answers range and conditional requests itself, with no code. A one-level name under `dws-cloud.com` is covered by the zone's Universal SSL certificate; a two-level name such as `data.bible.dws-cloud.com` may need an advanced certificate, so check before choosing one.

**Option B: a route in the bible-web Worker.** Bind the bucket in bible-web's Wrangler config (`[[r2_buckets]]`, `binding = "BIBLE_DATA"`, `bucket_name = "bible-data"`) and answer `/data/*` from it: `env.BIBLE_DATA.get(key, { range: request.headers, onlyIf: request.headers })`, then the body with `object.writeHttpMetadata(headers)` and the ETag, a 206 with `Content-Range` for a range, a 304 or 412 for a failed condition, and a 404 for no object. This keeps the plan's URL. It puts code that must handle ranges correctly on the download path, runs the Worker on every request, caches nothing at the edge unless the Worker uses the Cache API, and ties data delivery to bible-web's deploys.

**Recommended: option A.** The app's downloads are resumable `URLSession` downloads, which depend on correct range and ETag handling, and every package is immutable and cacheable for a year. A custom domain gives both with nothing to write or deploy. The app reads only the manifest URL and the `base_url` inside it, so it does not need the web reader's origin. The keys keep their `data/` prefix, so moving to option B later changes no object. Choosing A changes plan decision 20's URL, and the app's manifest URL becomes `https://bible-data.dws-cloud.com/data/manifest.json`.

## 5. Publish

Push a release tag, or, for a tag that was released before `R2_ENABLED` was set, open Actions, Release, Run workflow, and enter the tag. Building a tag again gives the same bytes, so the provenance release is updated in place and the publish job uploads what is missing.

Check the result, with the chosen base URL:

```sh
base=https://bible.dws-cloud.com/data/
curl -sI "${base}manifest.json" | grep -i cache-control         # public, max-age=300
curl -s "${base}manifest.json" -o manifest.json && swift run bible-pack manifest validate manifest.json
curl -s -r 0-99 -o /dev/null -w '%{http_code}\n' "${base}bsb-2026.10.bible.xz"   # 206
```
