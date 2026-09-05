{{ config(
    materialized='table',
    schema='mart_info'
) }}

WITH snapshot_wands AS (
    SELECT
        wand_id,
        wand_name,
        wand_description,
        wand_effects,
        ingested_at,
        loaded_at,
        dbt_valid_from,
        COALESCE(dbt_valid_to, '9999-12-31 23:59:59.999999'::TIMESTAMP_NTZ) AS dbt_valid_to
    FROM {{ ref('int_18_wands_snapshot') }}
),

add_patch_version AS (
    SELECT
        w.*,
        COALESCE(p.patch_version, 'Unknown') AS patch_version
    FROM snapshot_wands w
    /* 
      BUSINESS JOIN LOGIC:
      Maps each snapshot version of an anomaly wand mechanic to its corresponding TFT game patch release window 
      based on when the snapshot record became active (dbt_valid_from).
    */
    LEFT JOIN {{ ref('tft_patch_version') }} p 
        ON w.dbt_valid_from >= p.patch_release_utc
        AND w.dbt_valid_from < p.patch_end_utc
),

hashing_wand_keys AS (
    SELECT
        *,
        md5(CONCAT(wand_id, '_', dbt_valid_from)) AS wand_version_sk,
        md5(wand_id)                              AS wand_sk
    FROM add_patch_version
)

SELECT
    wand_version_sk,
    wand_sk,
    wand_id,
    wand_name,
    wand_description,
    wand_effects,
    patch_version,
    dbt_valid_from,
    dbt_valid_to,
    ingested_at,
    loaded_at
FROM hashing_wand_keys