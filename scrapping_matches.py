from datetime import datetime, timezone
import glob
import json
import os
import time
from dotenv import load_dotenv
import pandas as pd
import requests

load_dotenv()

# ==========================================================
# CONFIGURATION & CONSTANTS
# ==========================================================
HEADERS = {"X-Riot-Token": os.getenv("RIOT_API_KEY")}

# Region Settings
REGION = "VN2"
ROUTING = "sea"

# Ingestion & Batch Settings
MATCH_COUNT_PER_PLAYER = 5  # Maximum matches fetched per player
BATCH_SIZE = 100  # Number of matches to pack into a single Parquet file

request_count = 0


# ==========================================================
# UTILITY FUNCTIONS
# ==========================================================
def pace_requests(response=None):
  """Handles proactive rate pacing and reactive HTTP 429 backoff."""
  global request_count

  # Reactive rate limiting: Respect Riot's Retry-After header if 429 occurs
  if response is not None and response.status_code == 429:
    retry_after = int(response.headers.get("Retry-After", 40))
    print(
        f"\n[RATE LIMIT 429] Throttled by Riot API! Backing off for"
        f" {retry_after}s...\n"
    )
    time.sleep(retry_after)
    return

  # Proactive pacing: 100 calls take ~100s, sleep 40s buffer to safely clear the 120s limit
  request_count += 1
  if request_count % 100 == 0:
    print(
        f"\n[PACE] Completed {request_count} requests. Sleeping 40s to safely"
        " clear rate limit...\n"
    )
    time.sleep(40)


def save_batch_to_parquet(batch_data, target_dir):
  """Encapsulates raw JSON payloads into compressed Bronze-layer Parquet files."""
  if not batch_data:
    return

  ingested_at = datetime.now(timezone.utc).isoformat()

  records = []
  for m in batch_data:
    records.append({
        "match_id": m.get("metadata", {}).get("match_id"),
        "game_datetime": m.get("info", {}).get("game_datetime"),
        "game_length": m.get("info", {}).get("game_length"),
        "tft_set_number": m.get("info", {}).get("tft_set_number"),
        # System audit timestamp matching pipeline execution time
        "ingested_at": ingested_at,
        # Preserve intact raw JSON string for downstream warehouse/silver flattening
        "raw_json": json.dumps(m, ensure_ascii=False),
    })

  df = pd.DataFrame(records)

  # Explicit type casting for clean schema alignment
  df["match_id"] = df["match_id"].astype("string")
  df["game_datetime"] = df["game_datetime"].astype("Int64")
  df["game_length"] = df["game_length"].astype("Float64")
  df["tft_set_number"] = df["tft_set_number"].astype("Int64")
  df["ingested_at"] = df["ingested_at"].astype("string")
  df["raw_json"] = df["raw_json"].astype("string")

  # Generate unique timestamped file path
  timestamp_str = datetime.now().strftime("%Y%m%d_%H%M%S")
  file_name = f"{target_dir}/batch_{timestamp_str}_{len(batch_data)}matches.parquet"

  # Write compressed columnar format
  df.to_parquet(file_name, engine="pyarrow", compression="snappy", index=False)
  print(
      f"\n>>> [FLUSH TO DISK] Persisted {len(batch_data)} matches to:"
      f" {file_name}\n"
  )


# ==========================================================
# STEP 1: Extract unique PUUIDs from raw player files
# ==========================================================
player_files = glob.glob(f"data/player/{REGION}/*.parquet")
player_files = [f for f in player_files if not f.endswith("all_players.parquet")]

if not player_files:
  print(
      f"Error: No player data found in 'data/player/{REGION}/'. Run the player"
      " scraper first."
  )
  exit(1)

puuid_set = set()
for file_path in player_files:
  try:
    df_players = pd.read_parquet(file_path, columns=["puuid"])
    puuid_set.update(df_players["puuid"].dropna().tolist())
  except Exception as e:
    print(f"Error parsing {file_path}: {e}")

print(f"[{REGION}] Successfully extracted {len(puuid_set)} unique PUUIDs.")

# ==========================================================
# STEP 2: Identify existing matches from historical Parquet files
# ==========================================================
output_dir = f"data/matches/{ROUTING}"
os.makedirs(output_dir, exist_ok=True)

existing_matches = set()
existing_parquet_files = glob.glob(f"{output_dir}/*.parquet")

# Read match_ids from existing Parquet files to prevent duplicate ingestion
for pf in existing_parquet_files:
  try:
    df_temp = pd.read_parquet(pf, columns=["match_id"])
    existing_matches.update(df_temp["match_id"].tolist())
  except Exception as e:
    print(f"Error reading existing Parquet file {pf}: {e}")

print(
    f"\n--- Region [{ROUTING.upper()}]: Found {len(existing_matches)} existing"
    " matches on disk ---"
)

# ==========================================================
# STEP 3: Collect and deduplicate Match IDs across PUUIDs
# ==========================================================
collected_match_ids = set()

for idx, puuid in enumerate(puuid_set, 1):
  url = f"https://{ROUTING}.api.riotgames.com/tft/match/v1/matches/by-puuid/{puuid}/ids"
  params = {"count": MATCH_COUNT_PER_PLAYER}

  try:
    res = requests.get(url, headers=HEADERS, params=params)
    pace_requests(res)

    if res.status_code == 200:
      match_ids = res.json()
      # Exclude matches already on disk AND matches discovered in earlier iterations
      new_ids = set(match_ids) - existing_matches - collected_match_ids
      collected_match_ids.update(new_ids)
      print(
          f"[{idx}/{len(puuid_set)}] PUUID {puuid[:8]}... -> Found"
          f" {len(new_ids)} new match IDs (Pool: {len(collected_match_ids)})"
      )
    elif res.status_code != 429:
      print(f"Failed to fetch IDs for {puuid[:8]}: Status {res.status_code}")
  except Exception as e:
    print(f"Connection error for PUUID {puuid[:8]}: {e}")

print(
    f"\n=> SUMMARY: {len(collected_match_ids)} unique matches queued for"
    f" download [{ROUTING.upper()}]."
)

# ==========================================================
# STEP 4: Download match details & batch flush to Parquet
# ==========================================================
current_batch = []

for idx, match_id in enumerate(collected_match_ids, 1):
  url = f"https://{ROUTING}.api.riotgames.com/tft/match/v1/matches/{match_id}"

  try:
    res = requests.get(url, headers=HEADERS)
    pace_requests(res)

    if res.status_code == 200:
      match_data = res.json()
      current_batch.append(match_data)
      print(
          f"[{idx}/{len(collected_match_ids)}] Ingested {match_id} | Buffer:"
          f" {len(current_batch)}/{BATCH_SIZE}"
      )

      # Flush buffer to disk when batch threshold is reached
      if len(current_batch) >= BATCH_SIZE:
        save_batch_to_parquet(current_batch, output_dir)
        current_batch.clear()

    elif res.status_code != 429:
      print(f"Failed to fetch match {match_id}: Status {res.status_code}")
  except Exception as e:
    print(f"Error fetching match {match_id}: {e}")

# Flush remaining matches in the final partial batch
if current_batch:
  save_batch_to_parquet(current_batch, output_dir)
  current_batch.clear()

print("\nIngestion pipeline finished successfully. All Bronze batches saved.")