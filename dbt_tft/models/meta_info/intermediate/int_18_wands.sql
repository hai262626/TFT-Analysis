{{config(
    materialized='view',
    schema='int_info'
) }}

WITH raw_wands AS (
    SELECT 
        *
    FROM {{ref('stg_18_items')}}
),

selected_appropriate_columns AS (
    SELECT
        item_id AS wand_id,
        item_name_raw AS wand_name,
        item_description AS wand_description,
        item_effects AS wand_effects,
        ingested_at,
        loaded_at
    FROM raw_wands
    WHERE item_category = 'Wand'
)

SELECT * FROM selected_appropriate_columns