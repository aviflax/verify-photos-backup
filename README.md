# 🚨🚨🚨 DO NOT USE THIS 🚨🚨🚨<br>🚨🚨🚨 IT *WILL* DELETE YOUR DATA 🚨🚨🚨

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

# verify-photos-backup

A tool for verifying that a local Photos library is fully backed up to a
Backblaze B2 bucket. It lists every object in the bucket, enumerates
every asset in the local Photos library (concurrently with the listing),
matches the two by `(date, size)`, and writes:

- `matched.csv` — one row per library asset that has a corresponding bucket
  object, with columns
  `creation_date,original_filename,size,bucket_key,bucket_last_modified`.
- `assets-not-found-in-bucket.csv` — one row per library asset with no match
  (i.e. potentially missing from the backup), columns
  `creation_date,original_filename,size`.

Matching is by `(date, size)`: a library asset matches a bucket object if the
asset's `creation_date` (formatted as `YYYY/MM/DD` in the device's local
timezone) equals the bucket key's date prefix, and the byte sizes are equal.
Each bucket object can match at most one library asset; if multiple assets
share the same date and size, they consume distinct bucket objects.

The natural thing would be to match by an asset identifier rather than by
`(date, size)`, but inspection of the bucket keys produced by the existing
backup pipeline shows that they appear to embed PhotoKit's
`PHAsset.localIdentifier` — a UUID that is *local to the device and library
that produced it*. A localIdentifier is regenerated when the library is
rebuilt or restored on a different device (a new Mac, a fresh install, an
iCloud Photos re-download, etc.), so the IDs encoded in older bucket keys no
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

## Usage

Set the following environment variables for B2 access:

- `B2_KEY_ID` — B2 application key ID
- `B2_APPLICATION_KEY` — B2 application key
- `B2_BUCKET` — bucket name
- `B2_S3_ENDPOINT` — S3 endpoint URL, e.g. `https://s3.us-west-002.backblazeb2.com`
- `B2_REGION` *(optional)* — overrides the region inferred from the endpoint

Then run:

```sh
swift run verify-backup [--debug]
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
  swift run verify-backup
```
