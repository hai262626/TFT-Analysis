{{config(
    materialized='view',
    schema='int_matches'
) }}

WITH int_participant_units AS (
    SELECT
        match_id,
        game_datetime,
        puuid,
        unit_name,
        sorted_items,
        num_items,
        unit_rarity,
        unit_tier,
        placement,
        ingested_at,
        loaded_at
    FROM {{ ref('int_18_participant_units') }}
),

flatten_and_select_appropriate_columns AS (
    SELECT
        ipu.match_id,
        ipu.game_datetime,
        ipu.puuid,
        ipu.unit_name,
        ipu.placement,
        i.value::STRING AS item_id,
        ipu.ingested_at,
        ipu.loaded_at
    FROM int_participant_units ipu,
    LATERAL FLATTEN(input => ipu.sorted_items) i
),

removed_set18_consumable_items_from_wands AS (
    SELECT
        fasac.match_id,
        fasac.game_datetime,
        fasac.puuid,
        fasac.unit_name,
        fasac.placement,
        fasac.item_id,
        fasac.ingested_at,
        fasac.loaded_at
    FROM flatten_and_select_appropriate_columns fasac
    LEFT JOIN {{ ref('dim_18_equipments') }} de
        ON fasac.item_id = de.equipment_id
    WHERE de.item_category != 'Consumable' OR de.item_category IS NULL
)

SELECT * FROM removed_set18_consumable_items_from_wands