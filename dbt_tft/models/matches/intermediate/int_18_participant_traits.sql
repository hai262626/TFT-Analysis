{{ config(
    materialized='view',
    schema='int_matches'
) }}

WITH int_participants AS (
    SELECT 
        *
    FROM {{ ref('int_18_participants') }}
),

flatten_participant_traits AS (
    SELECT
        ip.match_id,
        ip.game_datetime,
        ip.puuid,
        ip.placement,
        p.value:name::STRING         AS trait_id,
        p.value:num_units::INT       AS num_units,
        p.value:style::INT           AS style,
        p.value:tier_current::INT    AS tier_current,
        p.value:tier_total::INT      AS tier_total,
        ip.ingested_at,
        ip.loaded_at
    FROM int_participants ip,
    LATERAL FLATTEN(input => ip.traits) p
),

/* 
  BUSINESS FILTER LOGIC:
  Inner join with catalog traits to eliminate orphan, inactive, 
  or unmapped trait definitions outside of Set 18 scope.
*/
filter_valid_traits AS (
    SELECT
        fpt.match_id,
        fpt.game_datetime,
        fpt.puuid,
        fpt.placement,
        fpt.trait_id,
        fpt.num_units,
        fpt.style,
        fpt.tier_current,
        fpt.tier_total,
        fpt.ingested_at,
        fpt.loaded_at
    FROM flatten_participant_traits fpt
    INNER JOIN {{ ref('int_18_traits') }} it
        ON fpt.trait_id = it.trait_id
)

SELECT
    match_id,
    game_datetime,
    puuid,
    placement,
    trait_id,
    num_units,
    style,
    tier_current,
    tier_total,
    ingested_at,
    loaded_at
FROM filter_valid_traits