import os
import glob
from pathlib import Path
from dotenv import load_dotenv
import boto3
from botocore.exceptions import ClientError

load_dotenv()

# ==========================================================
# CONFIGURATION
# ==========================================================
AWS_ACCESS_KEY_ID = os.getenv("AWS_ACCESS_KEY_ID")
AWS_SECRET_ACCESS_KEY = os.getenv("AWS_SECRET_ACCESS_KEY")
AWS_REGION = os.getenv("AWS_REGION", "ap-southeast-1")
BUCKET_NAME = os.getenv("AWS_S3_BUCKET_NAME")

LOCAL_DATA_DIR = "data"

if not BUCKET_NAME:
    print("[ABORT] AWS_S3_BUCKET_NAME is not configured in .env.")
    exit(1)

s3_client = boto3.client(
    "s3",
    aws_access_key_id=AWS_ACCESS_KEY_ID,
    aws_secret_access_key=AWS_SECRET_ACCESS_KEY,
    region_name=AWS_REGION,
)


def get_existing_s3_metadata(bucket_name: str) -> dict:
    """
    Fetches a map of {Key: FileSizeInBytes} for all objects currently in the S3 bucket.
    Uses pagination to handle arbitrary bucket sizes without memory issues.
    """
    s3_objects = {}
    paginator = s3_client.get_paginator("list_objects_v2")

    try:
        for page in paginator.paginate(Bucket=bucket_name):
            if "Contents" in page:
                for obj in page["Contents"]:
                    s3_objects[obj["Key"]] = obj["Size"]
    except ClientError as e:
        print(f"[ERROR] Failed to query bucket '{bucket_name}': {e}")
        exit(1)

    return s3_objects


def sync_local_to_s3(source_dir: str, bucket_name: str):
    """
    Synchronizes local Parquet files to S3 Bronze storage.
    Evaluates both file existence and byte-size consistency:
      - Match batches: upload once, skip indefinitely.
      - raw_* tables (players, items, champions): upload only if size changed (diff/delta).
    """
    if not os.path.exists(source_dir):
        print(f"[ABORT] Local directory '{source_dir}' does not exist.")
        return

    # Find all Parquet files recursively
    local_files = glob.glob(f"{source_dir}/**/*.parquet", recursive=True)
    if not local_files:
        print(f"[INFO] No Parquet files detected in '{source_dir}'.")
        return

    print(f"Inspecting existing objects in bucket 's3://{bucket_name}'...")
    existing_s3_objects = get_existing_s3_metadata(bucket_name)

    uploaded_count = 0
    skipped_count = 0

    print(f"Identified {len(local_files)} local files. Evaluating delta sync...\n")

    for file_path in local_files:
        # Standardize key path format for S3 (replace backslashes on Windows)
        s3_key = Path(file_path).as_posix()
        local_size = os.path.getsize(file_path)

        # File already exists on S3 with the identical byte size -> Purely untouched, skip
        if s3_key in existing_s3_objects and existing_s3_objects[s3_key] == local_size:
            skipped_count += 1
            continue

        # Determine log status
        if s3_key in existing_s3_objects:
            status = "DELTA_UPDATED"  # Existing file with modified byte size
        else:
            status = "NEW_UPLOADED"   # Fresh batch or new entity file

        try:
            s3_client.upload_file(file_path, bucket_name, s3_key)
            uploaded_count += 1
            print(f"[{status}] {file_path} ({local_size:,} bytes) -> s3://{bucket_name}/{s3_key}")
        except ClientError as e:
            print(f"[FAILED] Could not upload {file_path}: {e}")

    print(f"\n[DONE] Pipeline sync complete: {uploaded_count} uploaded/synced, {skipped_count} unchanged (skipped).")


if __name__ == "__main__":
    sync_local_to_s3(LOCAL_DATA_DIR, BUCKET_NAME)