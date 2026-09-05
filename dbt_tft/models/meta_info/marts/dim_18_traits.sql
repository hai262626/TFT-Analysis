{{ config(
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
        COALESCE(dbt_valid_to, '9999-12-31 23:59:59.999999'::TIMESTAMP_NTZ) AS dbt_valid_to
    FROM {{ ref('int_18_traits_snapshot') }}
),

add_patch_version AS (
    SELECT
        t.*,
        COALESCE(p.patch_version, 'Unknown') AS patch_version
    FROM snapshot_traits t
    /* 
      BUSINESS JOIN LOGIC:
      Maps each snapshot version of a trait definition to its corresponding TFT game patch release window 
      based on when the snapshot record became active (dbt_valid_from).
    */
    LEFT JOIN {{ ref('tft_patch_version') }} p 
        ON t.dbt_valid_from >= p.patch_release_utc
        AND t.dbt_valid_from < p.patch_end_utc
),

hashing_trait_id AS (
    SELECT
        *,
        md5(CONCAT(trait_id, '_', dbt_valid_from)) AS trait_version_sk,
        md5(trait_id)                              AS trait_sk
    FROM add_patch_version
)

SELECT
    trait_version_sk,
    trait_sk,
    set_number,
    trait_id,
    trait_name,
    trait_description,
    patch_version,
    dbt_valid_from,
    dbt_valid_to,
    ingested_at,
    loaded_at
FROM hashing_trait_id