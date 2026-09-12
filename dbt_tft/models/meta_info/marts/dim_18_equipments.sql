{{ config(
    materialized='table',
    schema='mart_info'
) }}

WITH snapshot_equipments AS (
    SELECT
        equipment_id,
        equipment_name,
        item_category,
        component_1,
        component_1_name,
        component_2,
        component_2_name,
        ingested_at,
        loaded_at,
    FROM {{ ref('int_18_equipments') }}
),

hashing_equipment_keys AS (
    SELECT
        md5(equipment_id)                              AS equipment_sk,
        equipment_id,
        equipment_name,
        item_category,
        component_1,
        component_1_name,
        component_2,
        component_2_name,
        ingested_at,
        loaded_at
    FROM snapshot_equipments
),

join_with_items_effects AS (
    SELECT
        hek.equipment_sk,
        hek.equipment_id,
        hek.equipment_name,
        hek.item_category,
        hek.component_1,
        hek.component_1_name,
        hek.component_2,
        hek.component_2_name,
        hek.ingested_at,
        hek.loaded_at,
        COALESCE(te.stats, 'Unknown') AS equipment_stats,
        COALESCE(te.effects, 'Unknown') AS equipment_effects,
    FROM hashing_equipment_keys hek
    LEFT JOIN {{ ref('tft_equipments') }} te
        ON hek.equipment_id = te.id
),

add_tier_zero AS (
    SELECT
        '-1'                                           AS equipment_sk,
        'Unknown'                                      AS equipment_id,
        'Unknown'                                      AS equipment_name,
        'Unknown'                                      AS item_category,
        NULL::STRING                                   AS component_1,
        NULL::STRING                                   AS component_1_name,
        NULL::STRING                                   AS component_2,
        NULL::STRING                                   AS component_2_name,
        '1900-01-01 00:00:00.000000'::TIMESTAMP_NTZ    AS ingested_at,
        '1900-01-01 00:00:00.000000'::TIMESTAMP_NTZ    AS loaded_at,
        'Unknown'                                      AS equipment_stats,
        'Unknown'                                      AS equipment_effects
),

union_with_tier_zero AS (
    SELECT * FROM join_with_items_effects
    UNION ALL
    SELECT * FROM add_tier_zero
)

SELECT
    equipment_sk,
    equipment_id,
    equipment_name,
    item_category,
    component_1,
    component_1_name,
    component_2,
    component_2_name,
    ingested_at,
    loaded_at,
    equipment_stats,
    equipment_effects
FROM union_with_tier_zero