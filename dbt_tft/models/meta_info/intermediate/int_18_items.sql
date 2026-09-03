{{config(
    materialized='view',
    schema='int_info'
) }}

WITH raw_items AS (
    SELECT 
        *
    FROM {{ref('stg_18_items')}}
    
),

stg_18_items AS (
    SELECT 
        item_id,
        item_name_raw,
        item_is_augment,
        item_unique,
        item_category,
        item_composition,
        ingested_at,
        loaded_at         
    FROM raw_items
    WHERE item_category IN ('CompleteItem', 'Artifact', 'Emblem', 'RadiantItem', 'Component')
)

SELECT * FROM stg_18_items