{{ config(
    materialized='view',
    schema='int_matches'
) }}

WITH int_participant_units AS (
    SELECT 
        *
    FROM {{ ref('int_18_participant_units') }}
),

flatten_unit_items AS (
    SELECT
        ipu.match_id,
        ipu.game_datetime,
        ipu.puuid,
        ipu.unit_index,
        ipu.champion_id,
        ipu.placement,
        i.index::INT                    AS item_index,
        i.value::STRING                 AS equipment_id,
        ipu.ingested_at,
        ipu.loaded_at
    FROM int_participant_units ipu,
    LATERAL FLATTEN(input => ipu.sorted_items) i
),

/* 
  BUSINESS FILTER LOGIC:
  Inner join with catalog equipments to validate item existence in Set 18 
  while strictly excluding consumable items/temporary wand effects.
*/
filter_valid_equipments AS (
    SELECT
        fui.match_id,
        fui.game_datetime,
        fui.puuid,
        fui.unit_index,
        fui.champion_id,
        fui.placement,
        fui.item_index,
        fui.equipment_id,
        fui.ingested_at,
        fui.loaded_at
    FROM flatten_unit_items fui
    INNER JOIN {{ ref('dim_18_equipments') }} de
        ON fui.equipment_id = de.equipment_id
       AND de.item_category != 'Consumable'
)

SELECT
    match_id,
    game_datetime,
    puuid,
    unit_index,
    champion_id,
    placement,
    item_index,
    equipment_id,
    ingested_at,
    loaded_at
FROM filter_valid_equipments