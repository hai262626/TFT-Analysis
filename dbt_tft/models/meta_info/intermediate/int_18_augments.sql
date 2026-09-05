{{config(
    materialized='view',
    schema='int_info'
) }}

WITH raw_augments AS (
    SELECT 
        *
    FROM {{ref('stg_18_items')}}
    
),

selected_appropriate_columns AS (
    SELECT 
        item_id AS augment_id,
        item_name_raw AS augment_name,
        item_description AS augment_description,
        item_effects AS augment_effects,
        item_associated_traits AS augment_associated_traits,
        ingested_at,
        loaded_at
    FROM raw_augments
    WHERE item_category = 'Augment'
)

SELECT * FROM selected_appropriate_columns
