{{config(
    materialized='view',
    schema='mart_info'
) }}

WITH snapshot_traits AS (
    SELECT
        set_number,
        trait_id,
        trait_name,
        trait_description,
        ingested_at,
        loaded_at,
        dbt_valid_from,
        COALESCE(dbt_valid_to, '9999-12-31 23:59:59.999999') AS dbt_valid_to
    FROM {{ ref('int_18_traits_snapshot') }}
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

hashing_trait_id AS (
    SELECT
        *,
        MD5(trait_id) AS trait_sk
    FROM add_patch_version
)


SELECT
    set_number,
    trait_sk,
    trait_id,
    trait_name,
    trait_description,
    dbt_valid_from,
    dbt_valid_to,
    patch_version
FROM hashing_trait_id