from datetime import datetime, timezone
import glob
import json
import os
import pandas as pd

# ==========================================================
# CONFIGURATION & PATHS
# ==========================================================
REGION = "VN2"
ROUTING = "sea"

MATCHES_DIR = f"data/matches/{ROUTING}"
OUTPUT_FILE = f"data/player/{REGION}/raw_players.parquet"

parquet_files = glob.glob(f"{MATCHES_DIR}/*.parquet")
if not parquet_files:
    print(f"[ABORT] No Bronze Parquet files found in '{MATCHES_DIR}'.")
    exit(0)

print(f"Scanning {len(parquet_files)} Parquet files for all participants...")

# Load pre-existing player registry to ensure incremental updates
players_registry = {}
if os.path.exists(OUTPUT_FILE):
    try:
        df_existing = pd.read_parquet(OUTPUT_FILE)
        players_registry = df_existing.set_index("puuid").to_dict(orient="index")
        for puuid_key, val in players_registry.items():
            val["puuid"] = puuid_key
        print(f"Loaded {len(players_registry)} existing players from history.")
    except Exception as e:
        print(f"[WARN] Could not read existing registry at {OUTPUT_FILE}: {e}")

pipeline_run_time = datetime.now(timezone.utc).isoformat()

# ==========================================================
# EXTRACT, AUDIT & DEDUPLICATE PLAYERS
# ==========================================================
for pf in parquet_files:
    try:
        # Load only target columns to optimize I/O and memory usage
        df = pd.read_parquet(pf, columns=["match_id", "raw_json"])

        for _, row in df.iterrows():
            match_id = row["match_id"]
            raw_payload = json.loads(row["raw_json"])

            # Actual game epoch millisecond timestamp from Riot API payload
            match_datetime = raw_payload.get("info", {}).get("game_datetime")
            participants = raw_payload.get("info", {}).get("participants", [])

            for p in participants:
                puuid = p.get("puuid")
                if not puuid:
                    continue

                game_name = p.get("riotIdGameName", "")
                tagline = p.get("riotIdTagline", "")

                # 1. New Player Discovery: Initialize boundary timestamps
                if puuid not in players_registry:
                    players_registry[puuid] = {
                        "puuid": puuid,
                        "riotIdGameName": game_name,
                        "riotIdTagline": tagline,
                        "first_seen_match_id": match_id,
                        "first_seen_match_time": match_datetime,
                        "last_seen_match_id": match_id,
                        "last_seen_match_time": match_datetime,
                        "updated_at": pipeline_run_time,
                    }

                # 2. Existing Player: Maintain Min/Max temporal boundaries
                else:
                    curr = players_registry[puuid]

                    # Backfill name and tagline if previously empty
                    if game_name and not curr["riotIdGameName"]:
                        curr["riotIdGameName"] = game_name
                    if tagline and not curr["riotIdTagline"]:
                        curr["riotIdTagline"] = tagline

                    # Update left boundary (Min: earliest historical match seen)
                    if match_datetime and (
                        curr["first_seen_match_time"] is None
                        or match_datetime < curr["first_seen_match_time"]
                    ):
                        curr["first_seen_match_time"] = match_datetime
                        curr["first_seen_match_id"] = match_id

                    # Update right boundary (Max: latest recent match seen)
                    if match_datetime and (
                        curr["last_seen_match_time"] is None
                        or match_datetime > curr["last_seen_match_time"]
                    ):
                        curr["last_seen_match_time"] = match_datetime
                        curr["last_seen_match_id"] = match_id

                    curr["updated_at"] = pipeline_run_time

    except Exception as e:
        print(f"[ERROR] Failed to read {pf}: {e}")

# ==========================================================
# PERSIST OUTPUT
# ==========================================================
os.makedirs(os.path.dirname(OUTPUT_FILE), exist_ok=True)

df_out = pd.DataFrame(list(players_registry.values()))
df_out.to_parquet(OUTPUT_FILE, engine="pyarrow", compression="snappy", index=False)

print(
    f"\n[DONE] Successfully consolidated {len(players_registry)} unique players "
    f"into '{OUTPUT_FILE}'."
)