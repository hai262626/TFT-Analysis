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

select_appropriate_columns AS (
    SELECT
        ip.match_id,
        ip.game_datetime,
        ip.puuid,
        ip.placement,
        p.value:character_id::STRING AS unit_name,
        ARRAY_SORT(p.value:itemNames) AS sorted_items,
        CASE
            WHEN ARRAY_SIZE(p.value:itemNames) > 3 THEN 3
            ELSE ARRAY_SIZE(p.value:itemNames)
        END AS num_items,
        p.value:rarity::INT AS unit_rarity,
        p.value:tier::INT AS unit_tier,
        ip.ingested_at,
        ip.loaded_at
    FROM int_participants ip,
    LATERAL FLATTEN(input => ip.units) p

),

removed_set18_orphan_units AS (
    SELECT
        sapc.match_id,
        sapc.game_datetime,
        sapc.puuid,
        sapc.unit_name,
        sapc.placement,
        sapc.sorted_items,
        sapc.num_items,
        sapc.unit_rarity,
        sapc.unit_tier,
        sapc.ingested_at,
        sapc.loaded_at
    FROM select_appropriate_columns sapc
    LEFT JOIN {{ ref('stg_18_champions') }} sc
        ON sapc.unit_name = sc.champion_id
    WHERE sc.champion_id IS NOT NULL
)

SELECT * FROM removed_set18_orphan_units