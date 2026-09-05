{{ config(
    materialized='incremental',
    schema='mart_matches',
    unique_key='match_id',
    incremental_strategy='delete+insert',
    on_schema_change='sync_all_columns'
)}}

WITH int_matches_info AS (
    SELECT 
        set_number,
        match_id,
        game_datetime,
        game_length,
        ingested_at,
        loaded_at
    FROM {{ ref('int_18_matches_info') }}

    {% if is_incremental() %}
        WHERE ingested_at > (
            SELECT DATEADD(day, -3, MAX(target.ingested_at)) 
            FROM {{ this }} AS target
        )
    {% endif %}
),

add_patch_version AS (
    SELECT
        imi.*,
        COALESCE(p.patch_version, 'Unknown') AS patch_version
    FROM int_matches_info imi
    LEFT JOIN  {{ ref('tft_patch_version') }} p 
        ON imi.game_datetime >= p.patch_release_utc
        AND imi.game_datetime < p.patch_end_utc
)

SELECT 
    set_number,
    match_id,
    game_datetime,
    game_length,
    patch_version,
    ingested_at,
    loaded_at
FROM add_patch_version