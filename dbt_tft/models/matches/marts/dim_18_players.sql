{{config(
    materialized='table',
    schema='mart_matches'
) }}

WITH stg_players AS (
    SELECT 
        * 
    FROM {{ ref('stg_18_players') }}
),

selected_appropriate_columns AS (
    SELECT
        PUUID,
        game_name,
        tagline,
        full_riot_id
    FROM stg_players
)

SELECT 
    PUUID,
    game_name,
    tagline,
    full_riot_id
FROM selected_appropriate_columns