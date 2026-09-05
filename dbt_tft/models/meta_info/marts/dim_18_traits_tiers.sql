{{ config(
    materialized='table',
    schema='mart_info'
) }}

WITH snapshot_traits AS (
    SELECT
        trait_id,
        tier_id,
        tier_level,
        min_units,
        max_units,
        style,
        tier_variables,
        ingested_at,
        loaded_at,
        dbt_valid_from,
        COALESCE(dbt_valid_to, '9999-12-31 23:59:59.999999') AS dbt_valid_to
    FROM {{ ref('int_18_traits_tiers_snapshot') }}
),

add_patch_version AS (
    SELECT
        t.*,
        COALESCE(p.patch_version, 'Unknown') AS patch_version
    FROM snapshot_traits t
    LEFT JOIN  {{ ref('tft_patch_version') }} p 
        ON t.dbt_valid_from >= p.patch_release_utc
        AND t.dbt_valid_from < p.patch_end_utc
),

hashing_trait_and_tier_id AS (
    SELECT
        *,
        MD5(trait_id) AS trait_sk,
        MD5(tier_id) AS tier_sk
    FROM add_patch_version
)

SELECT
    trait_sk,
    trait_id,
    tier_sk,
    tier_id,
    tier_level,
    min_units,
    max_units,
    style,
    tier_variables,
    dbt_valid_from,
    dbt_valid_to,
    patch_version
FROM hashing_trait_and_tier_id