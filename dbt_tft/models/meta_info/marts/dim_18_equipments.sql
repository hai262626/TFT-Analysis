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
    /* 
      BUSINESS JOIN LOGIC:
      Maps each snapshot version of an equipment/item to its corresponding TFT game patch release window 
      based on when the snapshot record became active (dbt_valid_from).
    */
    LEFT JOIN {{ ref('tft_patch_version') }} p 
        ON e.dbt_valid_from >= p.patch_release_utc
        AND e.dbt_valid_from < p.patch_end_utc
),

hashing_equipment_keys AS (
    SELECT
        *,
        md5(CONCAT(equipment_id, '_', dbt_valid_from)) AS equipment_version_sk,
        md5(equipment_id)                              AS equipment_sk
    FROM add_patch_version
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
FROM hashing_equipment_keys