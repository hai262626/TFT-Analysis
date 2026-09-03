{{config(
    materialized='view',
    schema='int_info'
) }}

WITH stg_18_items AS (
    SELECT 
        item_id,
        item_name_raw,
        item_is_augment,
        item_unique,
        item_category,
        item_description,
        icon_path,
        item_effects,
        item_composition,
        item_associated_traits,
        item_incompatible_traits,
        item_from,
        ingested_at,
        loaded_at         
    FROM {{ref('stg_18_items')}}
    WHERE item_category IN ('CompleteItem', 'Artifact', 'Emblem', 'RadiantItem', 'Component')
)

SELECT * FROM stg_18_items