{{config(
    materialized='view',
    schema='int_info'
) }}

WITH raw_equipments AS (
    SELECT 
        *
    FROM {{ref('stg_18_items')}}
),

selected_approprate_columns AS (
    SELECT 
        item_id AS equipment_id,
        item_name_raw AS equipment_name,
        item_category,
        item_composition AS component_composition,
        ingested_at,
        loaded_at         
    FROM raw_equipments
    WHERE item_category IN ('CompleteItem', 'Artifact', 'Emblem', 'RadiantItem', 'Component', 'Consumable')
),

split_components AS (
    SELECT
        equipment_id,
        equipment_name,
        item_category,
        component_composition[0]::STRING AS component_1,
        component_composition[1]::STRING AS component_2,
        ingested_at,
        loaded_at
    FROM selected_approprate_columns
),

add_name_to_components AS (
    SELECT
        sc.equipment_id,
        sc.equipment_name,
        sc.item_category,
        sc.component_1,
        i1.equipment_name AS component_1_name,
        sc.component_2,
        i2.equipment_name AS component_2_name,
        sc.ingested_at,
        sc.loaded_at
    FROM split_components sc
    LEFT JOIN split_components i1 ON sc.component_1 = i1.equipment_id
    LEFT JOIN split_components i2 ON sc.component_2 = i2.equipment_id
)

SELECT  
    equipment_id,
    equipment_name,
    item_category,
    component_1,
    component_1_name,
    component_2,
    component_2_name,
    ingested_at,
    loaded_at
FROM add_name_to_components