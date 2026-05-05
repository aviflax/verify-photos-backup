# verify-photos-backup

A small Swift script that downloads the list of all object keys in a Backblaze B2
bucket (via its S3-compatible API) and writes them to a text file, one key per line.

## Usage

Set the following environment variables:

- `B2_KEY_ID` — B2 application key ID
- `B2_APPLICATION_KEY` — B2 application key
- `B2_BUCKET` — bucket name
- `B2_S3_ENDPOINT` — S3 endpoint URL, e.g. `https://s3.us-west-002.backblazeb2.com`
- `B2_REGION` *(optional)* — overrides the region inferred from the endpoint

Then run:

```sh
swift run verify-photos-backup [output-path]
```

`output-path` defaults to `keys.txt` in the current directory.

### Example

```sh
B2_KEY_ID=00xxxxxxxxxxxxx \
B2_APPLICATION_KEY=K00xxxxxxxxxxxxxxxxxxxxxxxxxxxx \
B2_BUCKET=my-photos \
B2_S3_ENDPOINT=https://s3.us-west-002.backblazeb2.com \
  swift run verify-photos-backup keys.txt
```

On completion the script prints the number of keys written.
