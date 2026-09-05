{{ config(
    materialized='view',
    schema='int_info'
) }}

WITH raw_equipments AS (
    SELECT 
        *
    FROM {{ ref('stg_18_items') }}
),

selected_appropriate_columns AS (
    SELECT 
        item_id                             AS equipment_id,
        item_name                           AS equipment_name,
        item_category,
        item_composition[0]::STRING         AS component_1,
        item_composition[1]::STRING         AS component_2,
        ingested_at,
        loaded_at         
    FROM raw_equipments
    /* 
      BUSINESS FILTER LOGIC:
      Filters exclusively for craftable and equippable game items, 
      excluding player augments, anomaly wands, and uncategorized internal assets.
    */
    WHERE item_category IN (
        'CompleteItem', 
        'Artifact', 
        'Emblem', 
        'RadiantItem', 
        'Component', 
        'Consumable'
    )
),

add_name_to_components AS (
    SELECT
        sac.equipment_id,
        sac.equipment_name,
        sac.item_category,
        sac.component_1,
        c1.equipment_name                   AS component_1_name,
        sac.component_2,
        c2.equipment_name                   AS component_2_name,
        sac.ingested_at,
        sac.loaded_at
    FROM selected_appropriate_columns sac
    LEFT JOIN selected_appropriate_columns c1 
        ON sac.component_1 = c1.equipment_id
    LEFT JOIN selected_appropriate_columns c2 
        ON sac.component_2 = c2.equipment_id
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