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
        dbt_valid_from,
        COALESCE(dbt_valid_to, '9999-12-31 23:59:59.999999'::TIMESTAMP_NTZ) AS dbt_valid_to
    FROM {{ ref('int_18_equipments_snapshot') }}
),

add_patch_version AS (
    SELECT
        e.*,
        COALESCE(p.patch_version, 'Unknown') AS patch_version
    FROM snapshot_equipments e
    LEFT JOIN {{ ref('tft_patch_version') }} p 
        ON e.dbt_valid_from >= p.patch_release_utc
        AND e.dbt_valid_from < p.patch_end_utc
),

hashing_equipment_keys AS (
    SELECT
        md5(CONCAT(equipment_id, '_', dbt_valid_from)) AS equipment_version_sk,
        md5(equipment_id)                              AS equipment_sk,
        equipment_id,
        equipment_name,
        item_category,
        component_1,
        component_1_name,
        component_2,
        component_2_name,
        patch_version,
        dbt_valid_from,
        dbt_valid_to,
        ingested_at,
        loaded_at
    FROM add_patch_version
),

add_tier_zero AS (
    SELECT
        '-1'                                           AS equipment_version_sk,
        '-1'                                           AS equipment_sk,
        'Unknown'                                      AS equipment_id,
        'Unknown'                                      AS equipment_name,
        'Unknown'                                      AS item_category,
        NULL::STRING                                   AS component_1,
        NULL::STRING                                   AS component_1_name,
        NULL::STRING                                   AS component_2,
        NULL::STRING                                   AS component_2_name,
        'Unknown'                                      AS patch_version,
        '1900-01-01 00:00:00.000000'::TIMESTAMP_NTZ    AS dbt_valid_from,
        '9999-12-31 23:59:59.999999'::TIMESTAMP_NTZ    AS dbt_valid_to,
        '1900-01-01 00:00:00.000000'::TIMESTAMP_NTZ    AS ingested_at,
        '1900-01-01 00:00:00.000000'::TIMESTAMP_NTZ    AS loaded_at
),

union_with_tier_zero AS (
    SELECT * FROM hashing_equipment_keys
    UNION ALL
    SELECT * FROM add_tier_zero
)

SELECT
    equipment_version_sk,
    equipment_sk,
    equipment_id,
    equipment_name,
    item_category,
    component_1,
    component_1_name,
    component_2,
    component_2_name,
    patch_version,
    dbt_valid_from,
    dbt_valid_to,
    ingested_at,
    loaded_at
FROM union_with_tier_zero