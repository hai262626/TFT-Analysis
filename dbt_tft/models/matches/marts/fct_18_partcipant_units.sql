{{ config(
    materialized='incremental',
    schema='mart_matches',
    unique_key=['match_id', 'puuid', 'champion_id', 'unit_tier'],
    incremental_strategy='delete+insert',
    on_schema_change='sync_all_columns'
) }}

WITH int_18_participant_units AS (
    SELECT
        *
    FROM {{ ref('int_18_participant_units') }}

    {% if is_incremental() %}
        WHERE ingested_at > (
            SELECT DATEADD(day, -3, MAX(target.ingested_at)) 
            FROM {{ this }} AS target
        )
    {% endif %}
),

deduplicate_participant_units AS (
    SELECT
        *
    FROM int_18_participant_units
    /* 
      BUSINESS FILTER LOGIC:
      Guarantees uniqueness per unit instance per player in a match 
      across incremental ingestion lookback windows.
    */
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY match_id, puuid, champion_id, unit_tier 
        ORDER BY ingested_at DESC, loaded_at DESC
    ) = 1
),

add_patch_version AS (
    SELECT
        dpu.*,
        COALESCE(p.patch_version, 'Unknown') AS patch_version
    FROM deduplicate_participant_units dpu
    /* 
      BUSINESS JOIN LOGIC:
      Maps each participant unit record to the active game patch version 
      based on the match starting timestamp (game_datetime).
    */
    LEFT JOIN {{ ref('tft_patch_version') }} p 
        ON dpu.game_datetime >= p.patch_release_utc
        AND dpu.game_datetime < p.patch_end_utc
),

join_champions_dimension AS (
    SELECT
        apv.match_id,
        apv.game_datetime,
        apv.puuid,
        apv.placement,
        COALESCE(dc.champion_sk, '-1')           AS champion_sk,
        COALESCE(dc.champion_version_sk, '-1')              AS champion_version_sk,
        apv.unit_index,
        apv.champion_id,
        apv.unit_tier,
        apv.unit_rarity,
        apv.num_items,
        apv.patch_version,
        apv.ingested_at,
        apv.loaded_at
    FROM add_patch_version apv
    /* 
      BUSINESS JOIN LOGIC:
      Enriches unit records with versioned surrogate keys from the Champions dimension 
      matching the specific game patch version.
    */
    LEFT JOIN {{ ref('dim_18_champions') }} dc
        ON apv.champion_id = dc.champion_id
        AND apv.patch_version = dc.patch_version
)

SELECT 
    match_id,
    game_datetime,
    puuid,
    placement,
    champion_version_sk,
    champion_sk,
    champion_id,
    unit_index,
    unit_tier,
    unit_rarity,
    num_items,
    patch_version,
    ingested_at,
    loaded_at
FROM join_champions_dimension