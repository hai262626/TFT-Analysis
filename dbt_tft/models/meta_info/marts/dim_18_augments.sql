{{ config(
    materialized='table',
    schema='mart_info'
) }}

WITH snapshot_augments AS (
    SELECT
        augment_id,
        augment_name,
        augment_description,
        augment_effects,
        augment_associated_traits,
        ingested_at,
        loaded_at,
        dbt_valid_from,
        COALESCE(dbt_valid_to, '9999-12-31 23:59:59.999999'::TIMESTAMP_NTZ) AS dbt_valid_to
    FROM {{ ref('int_18_augments_snapshot') }}
),

add_patch_version AS (
    SELECT
        a.*,
        COALESCE(p.patch_version, 'Unknown') AS patch_version
    FROM snapshot_augments a
    /* 
      BUSINESS JOIN LOGIC:
      Maps each snapshot version of an augment to its corresponding TFT game patch release window 
      based on when the snapshot record became active (dbt_valid_from).
    */
    LEFT JOIN {{ ref('tft_patch_version') }} p 
        ON a.dbt_valid_from >= p.patch_release_utc
        AND a.dbt_valid_from < p.patch_end_utc
),

hash_surrogate_key AS (
    SELECT
        *,
        md5(CONCAT(augment_id, '_', dbt_valid_from)) AS augment_version_sk,
        md5(augment_id)                              AS augment_sk
    FROM add_patch_version
)

SELECT
    augment_version_sk,
    augment_sk,
    augment_id,
    augment_name,
    augment_description,
    augment_effects,
    augment_associated_traits,
    patch_version,
    dbt_valid_from,
    dbt_valid_to,
    ingested_at,
    loaded_at
FROM hash_surrogate_key