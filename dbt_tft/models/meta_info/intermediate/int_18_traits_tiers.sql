{{ config(
    materialized='view',
    schema='int_info'
) }}

WITH stg_traits AS (
    SELECT 
        *
    FROM {{ ref('stg_18_traits') }}
),

flatten_trait_tiers AS (
    SELECT
        s.trait_id,
        CONCAT(s.trait_id, '_tier_', f.index + 1) AS tier_id,
        (f.index + 1)::INT                       AS tier_level,
        f.value:minUnits::INT                    AS min_units,
        f.value:maxUnits::INT                    AS max_units,
        f.value:style::INT                       AS style,
        f.value:variables::VARIANT               AS tier_variables,
        s.ingested_at,
        s.loaded_at
    FROM stg_traits s,
    LATERAL FLATTEN(input => s.trait_effects) f
),

/* 
  BUSINESS LOGIC:
  Add an explicit Tier 0 record for each trait.
  This handles scenarios where players have active units belonging to a trait 
  but have not met the minimum unit threshold required to activate Tier 1.
*/
add_tier_zero AS (
    SELECT
        trait_id,
        tier_id,
        tier_level,
        min_units,
        max_units,
        style,
        tier_variables,
        ingested_at,
        loaded_at
    FROM flatten_trait_tiers

    UNION ALL

    SELECT
        s.trait_id,
        CONCAT(s.trait_id, '_tier_0')            AS tier_id,
        0                                        AS tier_level,
        0                                        AS min_units,
        0                                        AS max_units,
        0                                        AS style,
        NULL::VARIANT                            AS tier_variables,
        s.ingested_at,
        s.loaded_at
    FROM stg_traits s
)

SELECT
    trait_id,
    tier_id,
    tier_level,
    min_units,
    max_units,
    style,
    tier_variables,
    ingested_at,
    loaded_at
FROM add_tier_zero