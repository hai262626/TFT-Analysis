{{config(
    materialized='view',
    schema='int_matches'
) }}

WITH int_participants AS (
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
        ingested_at,
        loaded_at
    FROM {{ ref('int_18_participants') }}
),

flatten_and_select_appropriate_columns AS (
    SELECT
    ip.match_id,
        ip.game_datetime,
        ip.puuid,
        ip.placement,
        p.value:name::STRING AS trait_name,
        p.value:num_units::INT AS num_units,
        p.value:style::INT AS style,
        p.value:tier_current::INT AS tier_current,
        p.value:tier_total::INT AS tier_total,
        ip.ingested_at,
        ip.loaded_at
    FROM int_participants ip,
    LATERAL FLATTEN(input => ip.traits) p
),

removed_set18_orphan_traits AS (
    SELECT
        fasac.match_id,
        fasac.game_datetime,
        fasac.puuid,
        fasac.placement,
        fasac.trait_name,
        fasac.num_units,
        fasac.style,
        fasac.tier_current,
        fasac.tier_total,
        fasac.ingested_at,
        fasac.loaded_at
    FROM flatten_and_select_appropriate_columns fasac
    LEFT JOIN {{ ref('int_18_traits') }} st
        ON fasac.trait_name = st.trait_id
    WHERE st.trait_id IS NOT NULL
)

SELECT * FROM removed_set18_orphan_traits



