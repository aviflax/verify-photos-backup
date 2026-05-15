# 🚨🚨🚨 DO NOT USE THIS 🚨🚨🚨<br>🚨🚨🚨 IT MIGHT DELETE YOUR DATA 🚨🚨🚨

**Copyright © 2026 Avi Flax. All Rights Reserved.**

**This source code is provided for reference only.**

**No use, modification, distribution, or reproduction is permitted without explicit written permission
from the copyright holder.**

**THE CODE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE CODE OR THE USE OR OTHER DEALINGS IN THE
CODE.**

# phobato

`phobato` (PHOto BAckup TOol) is a CLI tool for working with backups of Apple Photos libraries in
S3-compatible network blob storage buckets.

It currently provides two subcommands:

- `phobato verify` — verifies that the local Photos library is fully backed
  up to a bucket.
- `phobato patch` — uploads the assets that the most recent `verify` run
  found missing.

Running `phobato` with no subcommand prints usage to stderr and exits 1.
Run `phobato --help`, `phobato verify --help`, or `phobato patch --help` for
full help text.

## `phobato verify`

Lists every object in the bucket, enumerates every asset in the local Photos
library (concurrently with the listing), matches the two by `(date, size)`,
and writes:

- `matched.csv` — one row per library asset that has a corresponding bucket
  object, with columns
  `creation_date,original_filename,size,bucket_key,bucket_last_modified`.
- `assets-not-found-in-bucket.csv` — one row per library asset with no match
  (i.e. potentially missing from the backup), columns
  `creation_date,original_filename,size,local_id,cloud_id`. `local_id` is
  `PHAsset.localIdentifier`; `cloud_id` is the stable
  `PHCloudIdentifier.stringValue` from
  `PHPhotoLibrary.cloudIdentifierMappings(forLocalIdentifiers:)`, or empty
  when PhotoKit has no cloud mapping for that asset.

Matching is by `(date, size)`: a library asset matches a bucket object if the
asset's `creation_date` (formatted as `YYYY/MM/DD` in the device's local
timezone) equals the bucket key's date prefix, and the byte sizes are equal.
Each bucket object can match at most one library asset; if multiple assets
share the same date and size, they consume distinct bucket objects.

The natural thing would be to match by an asset identifier rather than by
`(date, size)`, but inspection of the bucket keys produced by the existing
backup pipeline shows that they appear to embed PhotoKit's
`PHAsset.localIdentifier` — an opaque string (of the form
`<UUID>/L0/<NNN>`) that is *local to the device and library that produced
it*. A localIdentifier is regenerated when the library is rebuilt or
restored on a different device (a new Mac, a fresh install, an iCloud
Photos re-download, etc.), so the IDs encoded in older bucket keys no
longer correspond to anything PhotoKit reports for the same photo today.
PhotoKit also exposes a stable `cloudIdentifier` via
`PHPhotoLibrary.cloudIdentifierMappings(forLocalIdentifiers:)`, but the
backup's keys don't use it. `(creation_date, size)` is the coarsest
identity that's stable across library rebuilds — coarse enough to risk
collisions when many assets share the same day and exact byte size, but in
practice good enough to flag the backup gaps this tool is meant to surface.

Assumes the bucket key prefixes were generated using the same local timezone
as the device running the tool. If the backup ran in a different timezone,
date-edge cases may misclassify by ±1 day.

### Usage

Set the following environment variables for B2 access:

- `B2_KEY_ID` — B2 application key ID
- `B2_APPLICATION_KEY` — B2 application key
- `B2_BUCKET` — bucket name
- `B2_S3_ENDPOINT` — S3 endpoint URL, e.g. `https://s3.us-west-002.backblazeb2.com`
- `B2_REGION` *(optional)* — overrides the region inferred from the endpoint

Then run:

```sh
swift run -c release phobato verify [--debug]
```

Each run creates a fresh report directory under `reports/`
(`reports/report-01/`, `reports/report-02/`, …) and writes `matched.csv` and
`assets-not-found-in-bucket.csv` there.

With `--debug`, the fetch stages also write `bucket-objects.csv` and
`library-assets.csv` (the raw listings of, respectively, every B2 object and
every Photos asset that was scanned) into the same report directory. Useful
for diagnosing a discrepancy without re-running the slow fetch steps against
the same data.

### Permissions

PhotoKit access on macOS requires the running terminal (Terminal, iTerm, etc.)
to have been granted access to your Photos library in
**System Settings → Privacy & Security → Photos**. The first run may fail
silently if access has not been granted; grant access and re-run.

### Example

```sh
B2_KEY_ID=00xxxxxxxxxxxxx \
B2_APPLICATION_KEY=K00xxxxxxxxxxxxxxxxxxxxxxxxxxxx \
B2_BUCKET=my-photos \
B2_S3_ENDPOINT=https://s3.us-west-002.backblazeb2.com \
  swift run -c release phobato verify
```

## `phobato patch`

Reads `assets-not-found-in-bucket.csv` from the most recent `verify` run and
uploads each missing asset's original data from the local Photos library to the
bucket.

### How it works

1. Finds the highest-numbered `reports/report-NN/` directory. Aborts if that
   directory is more than one hour old (run `phobato verify` first).
2. Creates a numbered output sub-directory `reports/report-NN/patch-NN/`.
3. Reads `assets-not-found-in-bucket.csv`. Rows without a `cloud_id` are
   skipped (they cannot be given a stable bucket key).
4. Prints the upload count and prompts `[y/N]` before starting. Any answer
   other than `y` / `yes` aborts cleanly.
5. For each asset (up to 4 concurrent uploads):
   - Does a `HEAD` request for the target key. If an object already exists
     with the correct byte size it is recorded as *skipped* (safe to re-run).
     A size mismatch is recorded as a *failure*.
   - Fetches the original resource via PhotoKit into a temp file. Assets
     offloaded to iCloud are downloaded automatically; a live progress segment
     shows MB downloaded / total MB across all in-flight downloads.
   - Uploads via S3 multipart upload (5 MB parts, 1 part at a time per asset).
     On a transient failure, retries up to 3 attempts with in-process resume so
     already-uploaded parts are not re-sent.

### Bucket key scheme

Keys are constructed from the asset's cloud identifier rather than its local
identifier, so they remain stable across library rebuilds:

```
YYYY/MM/DD/<cloud_id>.<ext>
```

`/` and `:` in the cloud ID are replaced with `_`. Extensions are normalized
(`jpg` → `jpeg`, `tif` → `tiff`).

### Output files

All files are written to `reports/report-NN/patch-NN/`:

- `patched.csv` — one row per successfully uploaded asset, columns
  `sequence,creation_date,original_filename,size,local_id,cloud_id,bucket_key`.
- `skipped_already_patched.csv` — assets whose key already existed in the
  bucket with the correct size (produced only when at least one is skipped).
- `patch_failures.csv` — assets that could not be uploaded, with an `error`
  column (produced only when at least one fails).
- `patch_errors.log` — timestamped error messages for failures (produced only
  when at least one fails).

### Usage

Uses the same B2 environment variables as `verify`. Run `phobato verify`
first, then within one hour run:

```sh
swift run -c release phobato patch
```

### Idempotency

Re-running `patch` against the same report directory is safe. Already-uploaded
assets are detected via `HEAD` and counted as skipped rather than re-uploaded.
