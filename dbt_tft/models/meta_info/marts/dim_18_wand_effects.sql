{{ config(
    materialized='view',
    schema='int_info'
) }}

WITH dim_wands AS (
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
    FROM {{ ref('dim_18_wands') }}
),

flatten_wand_effects AS (
    SELECT
        w.wand_version_sk,
        w.wand_sk,
        w.wand_id,
        w.wand_name,
        w.wand_description,
        p.key::STRING AS wand_effect_key,
        ROUND(p.value::FLOAT, 2) AS wand_effect_value,
        w.patch_version,
        w.dbt_valid_from,
        w.dbt_valid_to,
        w.ingested_at,
        w.loaded_at
    FROM dim_wands w,
    LATERAL FLATTEN(input => w.wand_effects) p
)

SELECT * FROM flatten_wand_effects