{{config(
    materialized='view',
    schema='int_info'
) }}

WITH stg_traits AS (
    SELECT 
        *
    FROM {{ref('stg_18_traits')}}
    
),

select_appropriate_columns AS (
    SELECT
        s.trait_id,
        CONCAT(s.trait_id, '_tier_', f.index + 1) as tier_id,
        f.index + 1 as tier_level,
        f.value:minUnits as min_units,
        f.value:maxUnits as max_units,
        f.value:style as style,
        f.value:variables::VARIANT as tier_variables,
        ingested_at,
        loaded_at
    FROM stg_traits s,
    LATERAL FLATTEN(input => s.trait_effects) f
),

add_tier_zero AS (
    SELECT * FROM select_appropriate_columns
    UNION ALL
    SELECT
        s.trait_id,
        CONCAT(s.trait_id, '_tier_0') as tier_id,
        0 as tier_level,
        0 as min_units,
        0 as max_units,
        0 as style,
        NULL as tier_variables,
        ingested_at,
        loaded_at
    FROM stg_traits s
)

SELECT * FROM add_tier_zero