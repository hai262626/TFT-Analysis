{{ config(
    materialized='view',
    schema='int_info'
) }}

WITH raw_augments AS (
    SELECT 
        *
    FROM {{ ref('stg_18_items') }}
),

selected_appropriate_columns AS (
    SELECT 
        item_id                 AS augment_id,
        item_name               AS augment_name,
        item_description        AS augment_description,
        item_effects            AS augment_effects,
        item_associated_traits  AS augment_associated_traits,
        ingested_at,
        loaded_at
    FROM raw_augments
    /* 
      BUSINESS FILTER LOGIC:
      Filters exclusively for player hexcore augments, 
      separating game-modifying enhancements from equippable items and special drop mechanics.
    */
    WHERE item_category = 'Augment'
)

SELECT
    augment_id,
    augment_name,
    augment_description,
    augment_effects,
    augment_associated_traits,
    ingested_at,
    loaded_at
FROM selected_appropriate_columns