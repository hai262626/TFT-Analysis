from datetime import datetime, timezone
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
TIERS = ["challenger", "grandmaster", "master"]
REGION = "VN2"
MAX_PLAYERS_PER_TIER = 50

HEADERS = {
    "X-Riot-Token": os.getenv("RIOT_API_KEY"),
}

PARAMS = {
    "queue": "RANKED_TFT",
}

request_count = 0
region_lower = REGION.lower()
output_dir = f"data/player/{REGION}"
os.makedirs(output_dir, exist_ok=True)

# ==========================================================
# INGESTION PIPELINE: SCRAPE TOP PLAYERS PER TIER
# ==========================================================
for tier in TIERS:
  url = f"https://{region_lower}.api.riotgames.com/tft/league/v1/{tier}"

  try:
    response = requests.get(url, headers=HEADERS, params=PARAMS)
    request_count += 1

    if response.status_code == 200:
      data = response.json()

      # Slice only the first 50 players from the entries list
      total_players = len(data.get("entries", []))
      entries = data.get("entries", [])[:MAX_PLAYERS_PER_TIER]

      ingested_at = datetime.now(timezone.utc).isoformat()

      records = []
      for player in entries:
        records.append({
            "puuid": player.get("puuid"),
            "summoner_id": player.get("summonerId"),
            "league_points": player.get("leaguePoints"),
            "rank": player.get("rank"),
            "wins": player.get("wins"),
            "losses": player.get("losses"),
            "tier": tier.upper(),
            "queue_type": data.get("queue"),
            "ingested_at": ingested_at,
            "raw_json": json.dumps(player, ensure_ascii=False),
        })

      df = pd.DataFrame(records)

      # Explicit type casting for clean schema alignment
      df["puuid"] = df["puuid"].astype("string")
      df["summoner_id"] = df["summoner_id"].astype("string")
      df["league_points"] = df["league_points"].astype("Int64")
      df["rank"] = df["rank"].astype("string")
      df["wins"] = df["wins"].astype("Int64")
      df["losses"] = df["losses"].astype("Int64")
      df["tier"] = df["tier"].astype("string")
      df["queue_type"] = df["queue_type"].astype("string")
      df["ingested_at"] = df["ingested_at"].astype("string")
      df["raw_json"] = df["raw_json"].astype("string")

      file_path = f"{output_dir}/{tier}.parquet"
      df.to_parquet(file_path, engine="pyarrow", compression="snappy", index=False)

      print(
          f"[{REGION} - {tier.upper()}] Sliced {len(df)}/"
          f"{total_players} players -> Saved to {file_path}"
      )

    elif response.status_code == 429:
      retry_after = int(response.headers.get("Retry-After", 40))
      print(
          f"Rate limit exceeded (429) on {tier}. Backing off for"
          f" {retry_after}s..."
      )
      time.sleep(retry_after)
    else:
      print(
          f"Failed to fetch {REGION} - {tier}: {response.status_code} -"
          f" {response.text}"
      )

  except Exception as e:
    print(f"Network error while fetching {tier}: {e}")

  # Proactive sleep if multiple tiers/regions are queried
  if request_count % 15 == 0:
    time.sleep(1)

print("\nPlayer scraping completed successfully.")