{{config(
    materialized='view',
    schema='staging_matches'
) }}


WITH source_data AS (
    SELECT 
        *
    FROM {{source('raw_data', 'raw_matches')}}
),

select_appropriate_columns AS (
    SELECT
        raw_payload:info:tft_set_number::STRING AS set_number,
        raw_payload:metadata:match_id::STRING AS match_id,
        raw_payload:metadata:participants::ARRAY AS participants,

        TO_TIMESTAMP_NTZ(raw_payload:info:game_datetime::BIGINT, 3) AS game_datetime,
        raw_payload:info:game_length::FLOAT AS game_length,
        raw_payload:info:game_version::STRING AS game_version,
        raw_payload:info:participants::ARRAY AS participants_info,
        ingested_at,
        loaded_at
    FROM source_data
    WHERE raw_payload:info:tft_set_number::STRING = '18'
)

SELECT
    set_number,
    match_id,
    participants,
    game_datetime,
    game_length,
    game_version,
    participants_info,
    ingested_at,
    loaded_at
FROM select_appropriate_columns