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
        COALESCE(dbt_valid_to, '9999-12-31 23:59:59.999999'::TIMESTAMP_NTZ) AS dbt_valid_to
    FROM {{ ref('int_18_traits_tiers_snapshot') }}
),

add_patch_version AS (
    SELECT
        t.*,
        COALESCE(p.patch_version, 'Unknown') AS patch_version
    FROM snapshot_traits t
    /* 
      BUSINESS JOIN LOGIC:
      Maps each snapshot version of a trait tier configuration to its corresponding TFT game patch release window 
      based on when the snapshot record became active (dbt_valid_from).
    */
    LEFT JOIN {{ ref('tft_patch_version') }} p 
        ON t.dbt_valid_from >= p.patch_release_utc
        AND t.dbt_valid_from < p.patch_end_utc
),

hashing_tier_keys AS (
    SELECT
        *,
        md5(CONCAT(tier_id, '_', dbt_valid_from)) AS tier_version_sk,
        md5(tier_id)                              AS tier_sk,
        md5(trait_id)                             AS trait_sk
    FROM add_patch_version
),

join_trait_dimension AS (
    SELECT
        htk.*,
        COALESCE(dt.trait_version_sk, 'Unknown') AS trait_version_sk
    FROM hashing_tier_keys htk
    /* 
      BUSINESS JOIN LOGIC:
      Joins with the SCD Type 2 parent Traits dimension on trait_id 
      and valid-time containment to inherit the precise version surrogate key.
    */
    LEFT JOIN {{ ref('dim_18_traits') }} dt
        ON htk.trait_id = dt.trait_id
        AND htk.dbt_valid_from >= dt.dbt_valid_from
        AND htk.dbt_valid_from < dt.dbt_valid_to
)

SELECT
    tier_version_sk,
    tier_sk,
    tier_id,
    trait_version_sk,
    trait_sk,
    trait_id,
    tier_level,
    min_units,
    max_units,
    style,
    tier_variables,
    patch_version,
    dbt_valid_from,
    dbt_valid_to,
    ingested_at,
    loaded_at
FROM join_trait_dimension