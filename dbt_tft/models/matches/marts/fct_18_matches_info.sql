{{ config(
    materialized='incremental',
    schema='mart_matches',
    unique_key='match_id',
    incremental_strategy='delete+insert',
    on_schema_change='sync_all_columns'
) }}

WITH int_matches_info AS (
    SELECT 
        *
    FROM {{ ref('int_18_matches_info') }}

    {% if is_incremental() %}
        WHERE ingested_at > (
            SELECT DATEADD(day, -3, MAX(target.ingested_at)) 
            FROM {{ this }} AS target
        )
    {% endif %}
),

deduplicate_matches AS (
    SELECT
        *
    FROM int_matches_info
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY match_id 
        ORDER BY ingested_at DESC, loaded_at DESC
    ) = 1
),

add_patch_version AS (
    SELECT
        dm.*,
        COALESCE(p.patch_version, 'Unknown') AS patch_version
    FROM deduplicate_matches dm
    /* 
      BUSINESS JOIN LOGIC:
      Maps each match to its respective TFT game patch release window 
      based on the exact game start timestamp (game_datetime).
    */
    LEFT JOIN {{ ref('tft_patch_version') }} p 
        ON dm.game_datetime >= p.patch_release_utc
        AND dm.game_datetime < p.patch_end_utc
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