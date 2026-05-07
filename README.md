# verify-photos-backup

A small Swift tool for verifying that a local Photos library is fully backed
up to a Backblaze B2 bucket. It lists every object in the bucket, enumerates
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
