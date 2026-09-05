

{{ config(
    materialized='incremental',
    schema='mart_matches',
    unique_key='match_id',
    incremental_strategy='delete+insert',
    on_schema_change='sync_all_columns'
)}}

WITH int_18_match_participants AS (
    SELECT
        match_id,
        game_datetime,
        puuid,
        game_name,
        tagline,
        companion_id,
        gold_left,
        last_round,
        level,
        placement,
        traits,
        units,
        win,
        ingested_at,
        loaded_at
    FROM {{ ref('int_18_participants') }}
    {% if is_incremental() %}
        WHERE ingested_at > (
            SELECT DATEADD(day, -3, MAX(target.ingested_at)) 
            FROM {{ this }} AS target
        )
    {% endif %}
),

add_patch_version AS (
    SELECT
        i18mp.*,
        COALESCE(p.patch_version, 'Unknown') AS patch_version
    FROM int_18_match_participants i18mp
    LEFT JOIN  {{ ref('tft_patch_version') }} p 
        ON i18mp.game_datetime >= p.patch_release_utc
        AND i18mp.game_datetime < p.patch_end_utc
)

SELECT 
    match_id,
    game_datetime,
    puuid,
    game_name,
    tagline,
    companion_id,
    gold_left,
    last_round,
    level,
    placement,
    traits,
    units,
    win,
    patch_version,
    ingested_at,
    loaded_at
FROM add_patch_version