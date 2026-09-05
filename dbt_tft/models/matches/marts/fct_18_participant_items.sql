{{ config(
    materialized='incremental',
    schema='mart_matches',
    unique_key='match_id',
    incremental_strategy='delete+insert',
    on_schema_change='sync_all_columns'
)}}

WITH int_18_participant_items AS (
    SELECT
        match_id,
        game_datetime,
        puuid,
        unit_name,
        placement,
        item_id,
        ingested_at,
        loaded_at
    FROM {{ ref('int_18_participant_items') }}
    {% if is_incremental() %}
        WHERE ingested_at > (
            SELECT DATEADD(day, -3, MAX(target.ingested_at)) 
            FROM {{ this }} AS target
        )
    {% endif %}
),

add_patch_version AS (
    SELECT
        i18pi.*,
        COALESCE(p.patch_version, 'Unknown') AS patch_version
    FROM int_18_participant_items i18pi
    LEFT JOIN  {{ ref('tft_patch_version') }} p 
        ON i18pi.game_datetime >= p.patch_release_utc
        AND i18pi.game_datetime < p.patch_end_utc
),

hash_unit_name_and_item_id AS (
    SELECT
        *,
        md5(unit_name) AS unit_sk,
        md5(item_id) AS item_sk
    FROM add_patch_version
)

SELECT
    match_id,
    game_datetime,
    puuid,
    unit_name,
    unit_sk,
    placement,
    item_id,
    item_sk,
    patch_version,
    ingested_at,
    loaded_at
FROM hash_unit_name_and_item_id