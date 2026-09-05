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
        COALESCE(dbt_valid_to, '9999-12-31 23:59:59.999999') AS dbt_valid_to
    FROM {{ ref('int_18_wands_snapshot') }}
),

add_patch_version AS (
    SELECT
        w.*,
        COALESCE(p.patch_version, 'Unknown') AS patch_version
    FROM snapshot_wands w
    LEFT JOIN  {{ ref('tft_patch_version') }} p 
        ON w.dbt_valid_from >= p.patch_release_utc
        AND w.dbt_valid_from < p.patch_end_utc
)

SELECT
    wand_id,
    wand_name,
    wand_description,
    wand_effects,
    dbt_valid_from,
    dbt_valid_to,
    patch_version
FROM add_patch_version