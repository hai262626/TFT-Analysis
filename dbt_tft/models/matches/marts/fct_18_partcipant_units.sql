{{ config(
    materialized='incremental',
    schema='mart_matches',
    unique_key='match_id',
    incremental_strategy='delete+insert',
    on_schema_change='sync_all_columns'
)}}

WITH int_18_participant_units AS (
    SELECT
        match_id,
        game_datetime,
        puuid,
        unit_name,
        placement,
        num_items,
        unit_rarity,
        unit_tier,
        ingested_at,
        loaded_at
    FROM {{ ref('int_18_participant_units') }}
    {% if is_incremental() %}
        WHERE ingested_at > (
            SELECT DATEADD(day, -3, MAX(target.ingested_at)) 
            FROM {{ this }} AS target
        )
    {% endif %}
),

add_patch_version AS (
    SELECT
        i18pu.*,
        COALESCE(p.patch_version, 'Unknown') AS patch_version
    FROM int_18_participant_units i18pu
    LEFT JOIN  {{ ref('tft_patch_version') }} p 
        ON i18pu.game_datetime >= p.patch_release_utc
        AND i18pu.game_datetime < p.patch_end_utc
),

hash_unit_name AS (
    SELECT
        *,
        md5(unit_name) AS unit_sk
    FROM add_patch_version
)

SELECT 
    match_id,
    game_datetime,
    puuid,
    unit_name,
    unit_sk,
    placement,
    num_items,
    unit_rarity,
    unit_tier,
    patch_version,
    ingested_at,
    loaded_at
FROM hash_unit_name