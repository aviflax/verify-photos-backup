# 🚨🚨🚨 DO NOT USE THIS 🚨🚨🚨<br>🚨🚨🚨 IT MIGHT DELETE YOUR DATA 🚨🚨🚨

**Copyright © 2026 Avi Flax. All Rights Reserved.**

**This source code is provided for reference only.**

**No use, modification, distribution, or reproduction is permitted without explicit written
permission from the copyright holder.**

**THE CODE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT
LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE CODE OR THE USE OR OTHER DEALINGS IN THE CODE.**

# phobato

`phobato` (PHOto BAckup TOol) is a CLI tool for verifying and patching backups of Apple Photos
libraries in S3-compatible buckets.

## What it does

1. **Verify** — lists every object in the bucket and enumerates every asset in the local Photos
   library (concurrently), then matches the two by `(creation_date, size)`
2. **Patch** — if any assets are missing from the bucket, prompts `[y/N]` and uploads them

## Usage

Set the following environment variables for S3-compatible bucket access:

- `PB_KEY_ID`
- `PB_APPLICATION_KEY`
- `PB_BUCKET` — bucket name
- `PB_S3_ENDPOINT` — S3 endpoint URL, e.g. `https://s3.us-west-002.backblazeb2.com`
- `PB_REGION` _(optional)_ — overrides the region inferred from the endpoint

Then run:

```sh
swift run -c release phobato [--debug]
```

Each run creates a fresh numbered report directory under `reports/`
(`reports/report-01/`, `reports/report-02/`, …). If any assets are missing,
`assets-not-found-in-bucket.csv` is written there with columns
`creation_date,original_filename,size,local_id,cloud_id`.

With `--debug`, also writes `matched.csv`, `bucket-objects.csv`, and
`library-assets.csv` into the report directory.

If uploads are confirmed, a numbered `patch-NN/` sub-directory is created
inside the report directory with:

- `patched.csv` — successfully uploaded assets, columns
  `sequence,creation_date,original_filename,size,local_id,cloud_id,bucket_key`
- `skipped_already_patched.csv` — assets already in the bucket with the
  correct size (only when at least one is skipped)
- `patch_failures.csv` — assets that could not be uploaded, with an `error`
  column (only when at least one fails)
- `patch_errors.log` — timestamped error messages for failures (only when at
  least one fails)

### Example

```sh
PB_KEY_ID=00xxxxxxxxxxxxx \
PB_APPLICATION_KEY=K00xxxxxxxxxxxxxxxxxxxxxxxxxxxx \
PB_BUCKET=my-photos \
PB_S3_ENDPOINT=https://s3.us-west-002.backblazeb2.com \
  swift run -c release phobato
```

## Matching

Assets are matched by `(creation_date, size)`: a library asset matches a
bucket object if its creation date (formatted `YYYY/MM/DD` in the device's
local timezone) equals the key's date prefix and the byte sizes are equal.
Each bucket object matches at most one library asset.

The natural approach would be to match by identifier, but the bucket keys embed
`PHAsset.localIdentifier` — an opaque string that is _local to the device and
library_ and is regenerated whenever the library is rebuilt or restored.
PhotoKit also exposes a stable `cloudIdentifier`, but the existing backup keys
don't use it. `(creation_date, size)` is stable across rebuilds, though coarse
enough to risk collisions when many assets share the same day and byte size.

Assumes the bucket key prefixes were generated in the same local timezone as
the device running the tool. Date-edge cases may misclassify by ±1 day if
timezones differ.

## Bucket key scheme

New keys (written by the patch phase) use the asset's cloud identifier:

```
YYYY/MM/DD/<cloud_id>.<ext>
```

`/` and `:` in the cloud ID are replaced with `_`. Extensions are normalized
(`jpg` → `jpeg`, `tif` → `tiff`). Assets without a cloud identifier are
skipped.

## Permissions

PhotoKit on macOS requires the running terminal to have been granted Photos
access in **System Settings → Privacy & Security → Photos**. The first run
may fail silently if access has not been granted; grant it and re-run.

## Idempotency

Re-running is safe. The patch phase checks each target key via `HEAD` before
uploading; assets already in the bucket with the correct size are counted as
skipped rather than re-uploaded.
