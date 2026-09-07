{{ config(
    materialized='view',
    schema='int_info'
) }}

WITH raw_wands AS (
    SELECT 
        *
    FROM {{ ref('stg_18_items') }}
),

selected_appropriate_columns AS (
    SELECT
        item_id                 AS wand_id,
        item_name               AS wand_name,
        item_description        AS wand_description,
        item_effects            AS wand_effects,
        ingested_at,
        loaded_at
    FROM raw_wands
    /* 
      BUSINESS FILTER LOGIC:
      Filters exclusively for Set 18 anomaly wand mechanics, 
      isolating them from standard champion equipments and augments.
    */
    WHERE item_category = 'Wand'
),

resolve_wand_effects AS (
    SELECT
        *,
        resolve_riot_template_effects(wand_description, wand_effects) AS wand_clean_effects
    FROM selected_appropriate_columns
)

SELECT
    wand_id,
    wand_name,
    wand_description,
    wand_clean_effects AS wand_effects,
    ingested_at,
    loaded_at
FROM resolve_wand_effects