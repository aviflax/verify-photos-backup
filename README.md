# verify-photos-backup

A small Swift project for verifying that a local Photos library is fully backed
up to a Backblaze B2 bucket.

The primary tool is `verify-backup`, which composes the full pipeline (list
the bucket, enumerate the library, match, and write the result) in a single
run. Three smaller scripts expose the individual stages over CSV files, useful
for diagnostics or for re-running a single stage:

1. `export-bucket-objects` — list every object in the bucket to a CSV.
2. `export-library-assets` — list every asset in the local Photos library to a CSV.
3. `match` — read both CSVs and produce `matched.csv` (assets
   that have a corresponding bucket object) and `not-found.csv` (assets with no
   match — i.e. potentially missing from the backup).

## Usage

### `export-bucket-objects`

Downloads the list of all objects in a Backblaze B2 bucket (via its
S3-compatible API) and writes them to a CSV file with one row per object.

The CSV has a header row and these columns:

- `key` — the object key
- `size` — size in bytes
- `last_modified` — upload timestamp in ISO 8601 (e.g. `2024-08-15T14:23:11Z`).
  This is the only date S3 exposes via `ListObjectsV2`; the photo's own
  creation date is encoded in the key prefix (`YYYY/MM/DD/...`).

Set the following environment variables:

- `B2_KEY_ID` — B2 application key ID
- `B2_APPLICATION_KEY` — B2 application key
- `B2_BUCKET` — bucket name
- `B2_S3_ENDPOINT` — S3 endpoint URL, e.g. `https://s3.us-west-002.backblazeb2.com`
- `B2_REGION` *(optional)* — overrides the region inferred from the endpoint

Then run:

```sh
swift run export-bucket-objects [output-path]
```

`output-path` defaults to `bucket-objects.csv` in the current directory.

#### Example

```sh
B2_KEY_ID=00xxxxxxxxxxxxx \
B2_APPLICATION_KEY=K00xxxxxxxxxxxxxxxxxxxxxxxxxxxx \
B2_BUCKET=my-photos \
B2_S3_ENDPOINT=https://s3.us-west-002.backblazeb2.com \
  swift run export-bucket-objects bucket-objects.csv
```

On completion the script prints the number of objects written.

### `export-library-assets`

Enumerates the local Photos library via PhotoKit and writes a CSV with one row
per asset, describing the **original** (unedited) version of each asset — the
`PHAssetResource` of type `.photo` or `.video`, which Apple's docs describe as
providing the original photo/video data for the asset. The columns are the
properties needed to match a library asset against bucket objects produced by
`export-bucket-objects`:

- `creation_date` — the asset's creation date in ISO 8601 (e.g. `1998-11-01T19:00:00Z`)
- `original_filename` — the resource's original filename, e.g. `IMG_1234.HEIC`
- `size` — size of the original resource in bytes

Run:

```sh
swift run export-library-assets [output-path]
```

`output-path` defaults to `library-assets.csv` in the current directory.

A `--diagnose` flag is also available; it skips the CSV output and instead
prints detailed property dumps for the first few assets to stderr (useful for
investigating the underlying PhotoKit objects).

#### Permissions

PhotoKit access on macOS requires the running terminal (Terminal, iTerm, etc.)
to have been granted access to your Photos library in
**System Settings → Privacy & Security → Photos**. The first run may fail
silently if access has not been granted; grant access and re-run.

### `match`

Reads `library-assets.csv` and `bucket-objects.csv` (the outputs of the two
scripts above) and writes:

- `matched.csv` — one row per library asset that has a corresponding bucket
  object, with columns `creation_date,original_filename,size,bucket_key,bucket_last_modified`.
- `not-found.csv` — one row per library asset with no match, columns
  `creation_date,original_filename,size`.

Matching is by `(date, size)`: a library asset matches a bucket object if the
asset's `creation_date` (formatted as `YYYY/MM/DD` in the current device's
local timezone) equals the bucket key's date prefix, and the byte sizes are
equal. Each bucket object can match at most one library asset; if multiple
assets share the same date and size, they consume distinct bucket objects.

Assumes the bucket key prefixes were generated using the same local timezone
as the device running this script. If the backup ran in a different timezone,
date-edge cases may misclassify by ±1 day.

Run:

```sh
swift run match [library-csv] [bucket-csv]
```

Defaults: `library-assets.csv` and `bucket-objects.csv` in the current
directory. Outputs are always written as `matched.csv` and `not-found.csv` in
the current directory.

### `verify-backup`

Runs the full pipeline in a single process: lists the B2 bucket, enumerates
the local Photos library (concurrently with the listing), matches the two,
and writes `matched.csv` and `not-found.csv`. Equivalent to running the three
scripts above in sequence, but without the intermediate CSV round-trips.

Set the same B2 environment variables as `export-bucket-objects` and grant
Photos access to the running terminal (see permissions note above), then run:

```sh
swift run verify-backup [--debug]
```

Each run creates a fresh report directory under `reports/` (`reports/report-01/`,
`reports/report-02/`, …) and writes `matched.csv` and `not-found.csv` there.

With `--debug`, the fetch stages also write `bucket-objects.csv` and
`library-assets.csv` into the same report directory, matching the output of
the standalone scripts. Useful for diagnosing a discrepancy without
re-running the slow fetch steps.
