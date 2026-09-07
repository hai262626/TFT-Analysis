{{ config(
    materialized='view',
    schema='int_info'
) }}

WITH dim_augments AS (
    SELECT 
        augment_version_sk,
        augment_sk,
        augment_id,
        augment_name,
        augment_description,
        augment_effects,
        augment_associated_trait,
        patch_version,
        dbt_valid_from,
        dbt_valid_to,
        ingested_at,
        loaded_at
    FROM {{ ref('dim_18_augments') }}
),

flatten_augment_effects AS (
    SELECT
        sa.augment_version_sk,
        sa.augment_sk,
        sa.augment_id,
        sa.augment_name,
        sa.augment_description,
        p.key::STRING AS augment_effect_key,
        ROUND(p.value::FLOAT, 2) AS augment_effect_value,
        sa.augment_associated_trait,
        sa.patch_version,
        sa.ingested_at,
        sa.loaded_at,
        sa.dbt_valid_from,
        sa.dbt_valid_to
    FROM dim_augments sa,
    LATERAL FLATTEN(input => sa.augment_effects) p
)

SELECT
    augment_version_sk,
    augment_sk,
    augment_id,
    augment_name,
    augment_description,
    augment_effect_key,
    augment_effect_value,
    augment_associated_trait,
    patch_version,
    ingested_at,
    loaded_at,
    dbt_valid_from,
    dbt_valid_to
FROM flatten_augment_effects
