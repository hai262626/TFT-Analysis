{{ config(
    materialized='table',
    schema='mart_info'
) }}

WITH snapshot_traits AS (
    SELECT
        trait_id,
        tier_id,
        tier_level,
        COALESCE(min_units, 0) AS min_units,
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
    LEFT JOIN {{ ref('tft_patch_version') }} p 
        ON t.dbt_valid_from >= p.patch_release_utc
        AND t.dbt_valid_from < p.patch_end_utc
),

hashing_tier_keys AS (
    SELECT
        md5(CONCAT(tier_id, '_', dbt_valid_from)) AS tier_version_sk,
        md5(tier_id)                              AS tier_sk,
        md5(trait_id)                             AS trait_sk,
        trait_id,
        tier_id,
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
    FROM add_patch_version
),

join_trait_dimension AS (
    SELECT
        htk.tier_version_sk,
        htk.tier_sk,
        htk.tier_id,
        COALESCE(dt.trait_version_sk, '-1')       AS trait_version_sk,
        htk.trait_sk,
        htk.trait_id,
        htk.tier_level,
        htk.min_units,
        htk.max_units,
        htk.style,
        htk.tier_variables,
        htk.patch_version,
        htk.dbt_valid_from,
        htk.dbt_valid_to,
        htk.ingested_at,
        htk.loaded_at
    FROM hashing_tier_keys htk
    LEFT JOIN {{ ref('dim_18_traits') }} dt
        ON htk.trait_id = dt.trait_id
        AND htk.dbt_valid_from >= dt.dbt_valid_from
        AND htk.dbt_valid_from < dt.dbt_valid_to
),

add_tier_zero AS (
    SELECT
        '-1'                                           AS tier_version_sk,
        '-1'                                           AS tier_sk,
        'Unknown'                                      AS tier_id,
        '-1'                                           AS trait_version_sk,
        '-1'                                           AS trait_sk,
        'Unknown'                                      AS trait_id,
        0                                              AS tier_level,
        0                                              AS min_units,
        0                                              AS max_units,
        0                                              AS style,
        NULL::VARIANT                                  AS tier_variables,
        'Unknown'                                      AS patch_version,
        '1900-01-01 00:00:00.000000'::TIMESTAMP_NTZ    AS dbt_valid_from,
        '9999-12-31 23:59:59.999999'::TIMESTAMP_NTZ    AS dbt_valid_to,
        '1900-01-01 00:00:00.000000'::TIMESTAMP_NTZ    AS ingested_at,
        '1900-01-01 00:00:00.000000'::TIMESTAMP_NTZ    AS loaded_at
),

union_with_tier_zero AS (
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

    UNION ALL

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
    FROM add_tier_zero
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
FROM union_with_tier_zero