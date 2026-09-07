{{ config(
    materialized='table',
    schema='mart_info'
) }}

WITH dim_traits_tiers AS (
    SELECT 
        trait_version_sk,
        trait_sk,
        trait_id,
        tier_version_sk,
        tier_sk,
        tier_id,
        tier_level,
        min_units,
        max_units,
        style,
        tier_variables,
        patch_version,
        ingested_at,
        loaded_at,
        dbt_valid_from,
        dbt_valid_to
    FROM {{ ref('dim_18_traits_tiers') }}
),

flatten_tier_variables AS (
    SELECT
        sa.trait_version_sk,
        sa.trait_sk,
        sa.trait_id,
        sa.tier_version_sk,
        sa.tier_sk,
        sa.tier_id,
        sa.tier_level,
        sa.min_units,
        sa.max_units,
        sa.style,
        p.key::STRING AS tier_variable_key,
        ROUND(p.value::FLOAT, 2) AS tier_variable_value,
        sa.patch_version,
        sa.ingested_at,
        sa.loaded_at,
        sa.dbt_valid_from,
        sa.dbt_valid_to
    FROM dim_traits_tiers sa,
    LATERAL FLATTEN(input => sa.tier_variables) p
)

SELECT
    trait_version_sk,
    trait_sk,
    trait_id,
    tier_version_sk,
    tier_sk,
    tier_id,
    tier_level,
    min_units,
    max_units,
    style,
    tier_variable_key,
    tier_variable_value,
    patch_version,
    ingested_at,
    loaded_at,
    dbt_valid_from,
    dbt_valid_to
FROM flatten_tier_variables
