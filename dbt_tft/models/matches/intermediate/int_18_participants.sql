{{ config(
    materialized='view',
    schema='int_matches'
) }}

WITH stg_matches AS (
    SELECT 
        *
    FROM {{ ref('stg_18_matches') }}
),

flatten_participants AS (
    SELECT
        m.match_id,
        m.game_datetime,

        -- Player Identifiers
        p.value:puuid::STRING                       AS puuid,
        p.value:riotIdGameName::STRING              AS game_name,
        p.value:riotIdTagline::STRING               AS tagline,
        CONCAT(
            p.value:riotIdGameName::STRING, 
            '#', 
            p.value:riotIdTagline::STRING
        )                                           AS full_riot_id,

        -- Match Performance & State Attributes
        p.value:companion:content_ID::STRING        AS companion_id,
        p.value:gold_left::INT                      AS gold_left,
        p.value:last_round::INT                     AS last_round,
        p.value:level::INT                          AS level,
        p.value:placement::INT                      AS placement,
        p.value:win::BOOLEAN                        AS win,

        -- Nested Sub-Entities
        p.value:traits::ARRAY                       AS traits,
        p.value:units::ARRAY                        AS units,

        -- Audit Metadata Timestamps
        m.ingested_at,
        m.loaded_at

    FROM stg_matches m,
    LATERAL FLATTEN(input => m.participants_info) p
)

SELECT
    match_id,
    game_datetime,
    puuid,
    game_name,
    tagline,
    full_riot_id,
    companion_id,
    gold_left,
    last_round,
    level,
    placement,
    win,
    traits,
    units,
    ingested_at,
    loaded_at
FROM flatten_participants