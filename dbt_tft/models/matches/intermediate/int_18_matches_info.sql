{{ config(
    materialized='view',
    schema='int_matches'
) }}

WITH stg_matches AS (
    SELECT 
        *
    FROM {{ ref('stg_18_matches') }}
)

SELECT
    set_number,
    match_id,
    game_datetime,
    game_length,
    game_version,
    ingested_at,
    loaded_at
FROM stg_matches