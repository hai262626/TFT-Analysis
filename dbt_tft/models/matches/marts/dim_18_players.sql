{{ config(
    materialized='table',
    schema='mart_matches'
) }}

WITH stg_players AS (
    SELECT 
        * 
    FROM {{ ref('stg_18_players') }}
),

deduplicate_latest_players AS (
    SELECT
        puuid,
        game_name,
        tagline,
        full_riot_id,
        first_seen_match_id,
        first_seen_match_time,
        last_seen_match_id,
        last_seen_match_time,
        updated_at,
        loaded_at
    FROM stg_players
    /* 
      BUSINESS FILTER LOGIC:
      Ensures 1:1 entity granularity by retaining only the latest player profile record 
      in case multiple updates occurred across match history ingestions.
    */
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY puuid 
        ORDER BY last_seen_match_time DESC NULLS LAST, updated_at DESC NULLS LAST
    ) = 1
)

SELECT 
    puuid,
    game_name,
    tagline,
    full_riot_id,
    first_seen_match_id,
    first_seen_match_time,
    last_seen_match_id,
    last_seen_match_time,
    updated_at,
    loaded_at
FROM deduplicate_latest_players