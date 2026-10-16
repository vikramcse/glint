# Remote sources

Glint can search files that live outside your Mac:

| Source | How Glint reaches it | Set up in Glint |
| --- | --- | --- |
| **Network shares** (SMB, NFS, AFP) | Mounted by macOS; read like a folder | Settings › Sources › Add › Folder or Network Share… |
| **S3 buckets** (AWS, Cloudflare R2, Backblaze B2, MinIO, Wasabi) | S3 API with an access key | Add › S3 Bucket… |

Whatever the source, indexing and search happen on your Mac. Bucket files are downloaded one at a time to be indexed, then deleted; only the index (text, vectors and thumbnails) is kept. Results stay searchable while a source is offline, and nothing is removed from the index until Glint can reach the source again and sees the file is gone.

Glint rescans network shares and buckets every 15 minutes, when a drive or share mounts, and when the Mac wakes.

## S3 buckets

Create a key that can only **list and read** the bucket. For AWS, a policy like:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": "s3:ListBucket", "Resource": "arn:aws:s3:::my-bucket" },
    { "Effect": "Allow", "Action": "s3:GetObject", "Resource": "arn:aws:s3:::my-bucket/*" }
  ]
}
```

| Service | Endpoint | Region | Path-style |
| --- | --- | --- | --- |
| Amazon S3 | `https://s3.<region>.amazonaws.com` | the bucket's region | off |
| Cloudflare R2 | `https://<account-id>.r2.cloudflarestorage.com` | `auto` | on |
| Backblaze B2 | `https://s3.<region>.backblazeb2.com` | e.g. `us-west-004` | off |
| MinIO and others | your server's URL | usually `us-east-1` | on |

Set **Folder (prefix)** to index part of a bucket, such as `photos/2024`. **Test Connection** lists the bucket and reports how many files Glint can index there.

The secret key is stored in your login Keychain (item "Glint remote source"), never in Glint's index, and is deleted when you remove the source.

## What gets indexed

- Files whose type Glint already indexes locally (images, video, audio, PDFs, documents), after your exclusion rules.
- Files over 4 GB are listed but not downloaded.

Opening, previewing or copying a bucket result downloads a copy to `~/Library/Caches/Glint/RemoteDownloads`, which Glint clears at launch.

## When a source is offline

The source shows **Not connected** in Settings. Common causes: no internet connection, a rotated or revoked key, or a renamed bucket. Indexed files stay searchable. Fix the cause (or remove and re-add the source with a new key); Glint retries on its own every 15 minutes and on wake.
