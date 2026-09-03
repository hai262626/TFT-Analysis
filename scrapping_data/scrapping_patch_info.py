from datetime import datetime, timezone
import json
import os
import pandas as pd
import requests

# ==========================================================
# CONFIGURATION
# ==========================================================
CDRAGON_URL = "https://raw.communitydragon.org/latest/cdragon/tft/en_us.json"
OUTPUT_DIR = "data/tft_info"
os.makedirs(OUTPUT_DIR, exist_ok=True)

print("Fetching full TFT catalog from CommunityDragon...")
res = requests.get(CDRAGON_URL)
if res.status_code != 200:
  print(f"[ERROR] Failed to fetch CDragon data: Status {res.status_code}")
  exit(1)

data = res.json()
ingested_at = datetime.now(timezone.utc).isoformat()

# ==========================================================
# 1. PROCESS raw_TFT_ITEMS (Full Items, Augments, Consumables)
# ==========================================================
raw_items = data.get("items", [])
items_records = []

for item in raw_items:
  api_name = item.get("apiName")
  if not api_name:
    continue

  items_records.append({
      "item_id": item.get("id"),
      "api_name": api_name,
      "name": item.get("name", ""),
      "icon_path": item.get("icon", ""),
      "desc": item.get("desc", ""),
      # Ingested audit timestamp
      "ingested_at": ingested_at,
      # Preserve entire intact dictionary without dropping any nested keys
      "raw_json": json.dumps(item, ensure_ascii=False),
  })

df_items = pd.DataFrame(items_records)
df_items["item_id"] = df_items["item_id"].astype("Int64")
for col in ["api_name", "name", "icon_path", "desc", "ingested_at", "raw_json"]:
  df_items[col] = df_items[col].astype("string")

items_path = f"{OUTPUT_DIR}/raw_tft_items.parquet"
df_items.to_parquet(
    items_path, engine="pyarrow", compression="snappy", index=False
)
print(f"[SUCCESS] Persisted {len(df_items)} items to {items_path}")


# ==========================================================
# 2. PROCESS raw_TFT_CHAMPIONS & raw_TFT_TRAITS (Across All Sets)
# ==========================================================
champions_records = []
traits_records = []

set_data = data.get("setData", [])

for s in set_data:
  set_number = s.get("number")
  mutator = s.get("mutator")
  set_name = s.get("name", "")

  # Process all champions in this set
  for champ in s.get("champions", []):
    api_name = champ.get("apiName")
    if not api_name:
      continue

    # Enrich with set contextual info before preserving raw JSON
    champ_payload = dict(champ)
    champ_payload["_set_number"] = set_number
    champ_payload["_mutator"] = mutator

    champions_records.append({
        "set_number": set_number,
        "mutator": mutator,
        "api_name": api_name,
        "character_id": champ.get("characterId", api_name),
        "name": champ.get("name", ""),
        "cost": champ.get("cost", 0),
        "ingested_at": ingested_at,
        "raw_json": json.dumps(champ_payload, ensure_ascii=False),
    })

  # Process all traits in this set
  for trait in s.get("traits", []):
    api_name = trait.get("apiName")
    if not api_name:
      continue

    # Enrich with set contextual info before preserving raw JSON
    trait_payload = dict(trait)
    trait_payload["_set_number"] = set_number
    trait_payload["_mutator"] = mutator

    traits_records.append({
        "set_number": set_number,
        "mutator": mutator,
        "api_name": api_name,
        "name": trait.get("name", ""),
        "ingested_at": ingested_at,
        "raw_json": json.dumps(trait_payload, ensure_ascii=False),
    })

# Write raw_tft_champions.parquet
df_champions = pd.DataFrame(champions_records)
if not df_champions.empty:
  df_champions["set_number"] = df_champions["set_number"].astype("Int64")
  df_champions["cost"] = df_champions["cost"].astype("Int64")
  for col in [
      "mutator",
      "api_name",
      "character_id",
      "name",
      "ingested_at",
      "raw_json",
  ]:
    df_champions[col] = df_champions[col].astype("string")

  champs_path = f"{OUTPUT_DIR}/raw_tft_champions.parquet"
  df_champions.to_parquet(
      champs_path, engine="pyarrow", compression="snappy", index=False
  )
  print(f"[SUCCESS] Persisted {len(df_champions)} champions to {champs_path}")

# Write raw_tft_traits.parquet
df_traits = pd.DataFrame(traits_records)
if not df_traits.empty:
  df_traits["set_number"] = df_traits["set_number"].astype("Int64")
  for col in ["mutator", "api_name", "name", "ingested_at", "raw_json"]:
    df_traits[col] = df_traits[col].astype("string")

  traits_path = f"{OUTPUT_DIR}/raw_tft_traits.parquet"
  df_traits.to_parquet(
      traits_path, engine="pyarrow", compression="snappy", index=False
  )
  print(f"[SUCCESS] Persisted {len(df_traits)} traits to {traits_path}")

print(
    "\nTFT Info ingestion pipeline completed. Files ready at data/tft_info/ for"
    " S3 synchronization."
)