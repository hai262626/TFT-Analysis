{{ config(
    materialized='incremental',
    schema='mart_matches',
    unique_key=['match_id', 'puuid'],
    incremental_strategy='delete+insert',
    on_schema_change='sync_all_columns'
) }}

WITH int_18_match_participants AS (
    SELECT
        *
    FROM {{ ref('int_18_participants') }}

    {% if is_incremental() %}
        WHERE ingested_at > (
            SELECT DATEADD(day, -3, MAX(target.ingested_at)) 
            FROM {{ this }} AS target
        )
    {% endif %}
),

deduplicate_participants AS (
    SELECT
        *
    FROM int_18_match_participants
    /* 
      BUSINESS FILTER LOGIC:
      Ensures strict 1:1 match-player granularity in case overlapping 
      incremental ingestion windows re-capture the same participant record.
    */
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY match_id, puuid 
        ORDER BY ingested_at DESC, loaded_at DESC
    ) = 1
),

add_patch_version AS (
    SELECT
        dp.*,
        COALESCE(p.patch_version, 'Unknown') AS patch_version
    FROM deduplicate_participants dp
    /* 
      BUSINESS JOIN LOGIC:
      Maps each participant match entry to the active TFT game patch release window 
      based on the match starting timestamp (game_datetime).
    */
    LEFT JOIN {{ ref('tft_patch_version') }} p 
        ON dp.game_datetime >= p.patch_release_utc
        AND dp.game_datetime < p.patch_end_utc
)

SELECT 
    match_id,
    game_datetime,
    puuid,
    game_name,
    tagline,
    companion_id,
    gold_left,
    last_round,
    level,
    placement,
    traits,
    units,
    win,
    patch_version,
    ingested_at,
    loaded_at
FROM add_patch_version