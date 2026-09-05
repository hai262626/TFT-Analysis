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
        COALESCE(dbt_valid_to, '9999-12-31 23:59:59.999999') AS dbt_valid_to
    FROM {{ ref('int_18_augments_snapshot') }}
),

add_patch_version AS (
    SELECT
        a.*,
        COALESCE(p.patch_version, 'Unknown') AS patch_version
    FROM snapshot_augments a
    LEFT JOIN  {{ ref('tft_patch_version') }} p 
        ON a.dbt_valid_from >= p.patch_release_utc
        AND a.dbt_valid_from < p.patch_end_utc
)

SELECT
    augment_id,
    augment_name,
    augment_description,
    augment_effects,
    augment_associated_traits,
    dbt_valid_from,
    dbt_valid_to,
    patch_version
FROM add_patch_version