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
AWS_REGION = os.getenv("AWS_REGION", "ap-southeast-2")
BUCKET_NAME = os.getenv("AWS_S3_BUCKET_NAME")

LOCAL_DATA_DIR = "data"

if not BUCKET_NAME:
    print("[ABORT] AWS_S3_BUCKET_NAME is not set in your .env file.")
    exit(1)

# Initialize S3 Client
s3_client = boto3.client(
    "s3",
    aws_access_key_id=AWS_ACCESS_KEY_ID,
    aws_secret_access_key=AWS_SECRET_ACCESS_KEY,
    region_name=AWS_REGION,
)


def get_existing_s3_keys(bucket_name):
    """Fetches all existing object keys in the bucket to prevent redundant uploads."""
    existing_keys = set()
    paginator = s3_client.get_paginator("list_objects_v2")
    
    try:
        for page in paginator.paginate(Bucket=bucket_name):
            if "Contents" in page:
                for obj in page["Contents"]:
                    existing_keys.add(obj["Key"])
    except ClientError as e:
        print(f"[ERROR] Failed to query bucket '{bucket_name}': {e}")
        exit(1)
        
    return existing_keys


def upload_all_files(source_dir, bucket_name):
    """Scans local data directory and uploads new/updated Parquet files to S3."""
    if not os.path.exists(source_dir):
        print(f"[ABORT] Local directory '{source_dir}' does not exist.")
        return

    # Find all Parquet files recursively
    local_files = glob.glob(f"{source_dir}/**/*.parquet", recursive=True)
    if not local_files:
        print(f"[INFO] No Parquet files found in '{source_dir}'.")
        return

    print(f"Checking existing files in bucket '{bucket_name}'...")
    existing_s3_keys = get_existing_s3_keys(bucket_name)

    uploaded_count = 0
    skipped_count = 0

    print(f"Found {len(local_files)} local files. Beginning synchronization...\n")

    for file_path in local_files:
        # Standardize key path format for S3 (replace Windows backslashes)
        s3_key = Path(file_path).as_posix()

        # Deduplication check: match batches are immutable, dim_players can be overwritten
        is_dim_table = "dim_players" in s3_key
        if s3_key in existing_s3_keys and not is_dim_table:
            skipped_count += 1
            continue

        try:
            s3_client.upload_file(file_path, bucket_name, s3_key)
            uploaded_count += 1
            status = "UPDATED" if is_dim_table and s3_key in existing_s3_keys else "UPLOADED"
            print(f"[{status}] {file_path} -> s3://{bucket_name}/{s3_key}")
        except ClientError as e:
            print(f"[FAILED] Could not upload {file_path}: {e}")

    print(f"\n[DONE] Synchronization complete: {uploaded_count} uploaded/updated, {skipped_count} skipped.")


if __name__ == "__main__":
    upload_all_files(LOCAL_DATA_DIR, BUCKET_NAME)