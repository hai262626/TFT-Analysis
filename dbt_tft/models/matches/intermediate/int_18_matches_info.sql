{{config(
    materialized='view',
    schema='int_matches'
) }}

WITH stg_matches AS (
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
    FROM {{ ref('stg_18_matches') }}
),

select_appropriate_columns AS (
    SELECT
        set_number,
        match_id,
        game_datetime,
        game_length,
        game_version,
        ingested_at,
        loaded_at
    FROM stg_matches
)


SELECT * FROM select_appropriate_columns