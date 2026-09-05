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

flatten_and_select_appropriate_columns AS (
    SELECT
        m.match_id,
        m.game_datetime,

        p.value:puuid::STRING AS puuid,
        p.value:riotIdGameName::STRING AS game_name,
        p.value:riotIdTagline::STRING AS tagline,

        p.value:companion:content_ID::STRING AS companion_id,
        p.value:gold_left::INT AS gold_left,
        p.value:last_round::INT AS last_round,
        p.value:level::INT AS level,
        p.value:placement::INT AS placement,
        p.value:traits::ARRAY AS traits,
        p.value:units::ARRAY AS units,
        p.value:win::BOOLEAN AS win,
        m.ingested_at,
        m.loaded_at

    FROM stg_matches m,
    LATERAL FLATTEN(input => m.participants_info) p
)

SELECT * FROM flatten_and_select_appropriate_columns