{{ config(
    materialized='view',
    schema='staging_matches'
) }}

WITH source_data AS (
    SELECT 
        *
    FROM {{ source('raw_data', 'raw_players') }}
),

select_appropriate_columns AS (
    SELECT
        -- Primary Identifiers
        puuid,
        riot_id_game_name                                           AS game_name,
        riot_id_tagline                                             AS tagline,
        CONCAT(riot_id_game_name, '#', riot_id_tagline)             AS full_riot_id,

        -- Player Activity Tracking (Converted from Epoch Milliseconds)
        first_seen_match_id,
        TO_TIMESTAMP_NTZ(first_seen_match_time / 1000)              AS first_seen_match_time,
        last_seen_match_id,
        TO_TIMESTAMP_NTZ(last_seen_match_time / 1000)               AS last_seen_match_time,

        -- Audit Metadata Timestamps
        CAST(updated_at AS TIMESTAMP_NTZ)                           AS updated_at,
        CAST(loaded_at AS TIMESTAMP_NTZ)                            AS loaded_at
    FROM source_data
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
FROM select_appropriate_columns