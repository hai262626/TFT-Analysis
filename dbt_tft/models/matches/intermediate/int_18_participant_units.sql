{{ config(
    materialized='view',
    schema='int_matches'
) }}

WITH int_participants AS (
    SELECT 
        *
    FROM {{ ref('int_18_participants') }}
),

flatten_participant_units AS (
    SELECT
        ip.match_id,
        ip.game_datetime,
        ip.puuid,
        ip.placement,
        p.index::INT                                    AS unit_index,
        p.value:character_id::STRING                    AS champion_id,
        ARRAY_SORT(p.value:itemNames)                   AS sorted_items,
        LEAST(ARRAY_SIZE(p.value:itemNames), 3)         AS num_items,
        p.value:rarity::INT                             AS unit_rarity,
        p.value:tier::INT                               AS unit_tier,
        ip.ingested_at,
        ip.loaded_at
    FROM int_participants ip,
    LATERAL FLATTEN(input => ip.units) p
),

/* 
  BUSINESS FILTER LOGIC:
  Inner join with valid Set 18 champions catalog to filter out target dummies, 
  summoned units (e.g. Tibbers, void spawns), and out-of-scope/orphan entities.
*/
filter_valid_champions AS (
    SELECT
        fpu.match_id,
        fpu.game_datetime,
        fpu.puuid,
        fpu.placement,
        fpu.unit_index,
        fpu.champion_id,
        fpu.sorted_items,
        fpu.num_items,
        fpu.unit_rarity,
        fpu.unit_tier,
        fpu.ingested_at,
        fpu.loaded_at
    FROM flatten_participant_units fpu
    INNER JOIN {{ ref('stg_18_champions') }} sc
        ON fpu.champion_id = sc.champion_id
)

SELECT
    match_id,
    game_datetime,
    puuid,
    placement,
    unit_index,
    champion_id,
    sorted_items,
    num_items,
    unit_rarity,
    unit_tier,
    ingested_at,
    loaded_at
FROM filter_valid_champions