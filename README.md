# verify-photos-backup

A small Swift project for verifying that a local Photos library is fully backed
up to a Backblaze B2 bucket. It contains two scripts: one that exports the keys
present in the bucket, and one that exports the keys that *should* be present
based on the local Photos library. Diffing their outputs reveals what is
missing.

## Usage

### `export-bucket-keys`

Downloads the list of all object keys in a Backblaze B2 bucket (via its
S3-compatible API) and writes them to a text file, one key per line.

Set the following environment variables:

- `B2_KEY_ID` — B2 application key ID
- `B2_APPLICATION_KEY` — B2 application key
- `B2_BUCKET` — bucket name
- `B2_S3_ENDPOINT` — S3 endpoint URL, e.g. `https://s3.us-west-002.backblazeb2.com`
- `B2_REGION` *(optional)* — overrides the region inferred from the endpoint

Then run:

```sh
swift run export-bucket-keys [output-path]
```

`output-path` defaults to `bucket-keys.txt` in the current directory.

#### Example

```sh
B2_KEY_ID=00xxxxxxxxxxxxx \
B2_APPLICATION_KEY=K00xxxxxxxxxxxxxxxxxxxxxxxxxxxx \
B2_BUCKET=my-photos \
B2_S3_ENDPOINT=https://s3.us-west-002.backblazeb2.com \
  swift run export-bucket-keys bucket-keys.txt
```

On completion the script prints the number of keys written.

### `export-library-keys`

Enumerates the local Photos library via PhotoKit and prints, for each asset,
the key under which it would be stored in the bucket (matching the format used
by `export-bucket-keys`). Currently limited to the first 20 assets for testing.

Run:

```sh
swift run export-library-keys
```

Output is written to stdout, one key per line. Redirect to a file if you want
to keep it:

```sh
swift run export-library-keys > library-keys.txt
```

#### Permissions

PhotoKit access on macOS requires the running terminal (Terminal, iTerm, etc.)
to have been granted access to your Photos library in
**System Settings → Privacy & Security → Photos**. The first run may fail
silently if access has not been granted; grant access and re-run.
