{{ config(
    materialized='incremental',
    schema='mart_matches',
    unique_key=['match_id', 'puuid', 'unit_index', 'item_index'],
    incremental_strategy='delete+insert',
    on_schema_change='sync_all_columns'
) }}

WITH int_18_participant_items AS (
    SELECT
        *
    FROM {{ ref('int_18_participant_items') }}

    {% if is_incremental() %}
        WHERE ingested_at > (
            SELECT DATEADD(day, -3, MAX(target.ingested_at)) 
            FROM {{ this }} AS target
        )
    {% endif %}
),

deduplicate_participant_items AS (
    SELECT
        *
    FROM int_18_participant_items
    /* 
      BUSINESS FILTER LOGIC:
      Removes duplicates caused by overlapping incremental lookback windows 
      using the native unit and item array indexes.
    */
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY match_id, puuid, unit_index, item_index 
        ORDER BY ingested_at DESC, loaded_at DESC
    ) = 1
),

add_patch_version AS (
    SELECT
        dpi.*,
        COALESCE(p.patch_version, 'Unknown') AS patch_version
    FROM deduplicate_participant_items dpi
    /* 
      BUSINESS JOIN LOGIC:
      Maps each equipped item event to the active game patch release window 
      based on the match starting timestamp (game_datetime).
    */
    LEFT JOIN {{ ref('tft_patch_version') }} p 
        ON dpi.game_datetime >= p.patch_release_utc
        AND dpi.game_datetime < p.patch_end_utc
),

join_dimensions AS (
    SELECT
        apv.match_id,
        apv.game_datetime,
        apv.puuid,
        apv.placement,
        apv.unit_index,
        COALESCE(dc.champion_sk, '-1')      AS champion_sk,
        COALESCE(dc.champion_version_sk, '-1')         AS champion_version_sk,
        apv.champion_id,
        apv.item_index,
        COALESCE(de.equipment_sk, '-1')    AS equipment_sk,
        apv.equipment_id,
        apv.patch_version,
        apv.ingested_at,
        apv.loaded_at
    FROM add_patch_version apv
    /* 
      BUSINESS JOIN LOGIC:
      Enriches item events with versioned surrogate keys from both Champions 
      and Equipments dimension catalogs matching the specific game patch version.
    */
    LEFT JOIN {{ ref('dim_18_champions') }} dc
        ON apv.champion_id = dc.champion_id
        AND apv.patch_version = dc.patch_version
    LEFT JOIN {{ ref('dim_18_equipments') }} de
        ON apv.equipment_id = de.equipment_id
)

SELECT
    match_id,
    game_datetime,
    puuid,
    placement,
    unit_index,
    champion_version_sk,
    champion_sk,
    champion_id,
    item_index,
    equipment_sk,
    equipment_id,
    patch_version,
    ingested_at,
    loaded_at
FROM join_dimensions