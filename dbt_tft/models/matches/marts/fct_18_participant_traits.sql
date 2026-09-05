{{ config(
    materialized='incremental',
    schema='mart_matches',
    unique_key=['match_id', 'puuid', 'trait_id'],
    incremental_strategy='delete+insert',
    on_schema_change='sync_all_columns'
) }}

WITH int_18_participant_traits AS (
    SELECT
        *
    FROM {{ ref('int_18_participant_traits') }}

    {% if is_incremental() %}
        WHERE ingested_at > (
            SELECT DATEADD(day, -3, MAX(target.ingested_at)) 
            FROM {{ this }} AS target
        )
    {% endif %}
),

deduplicate_participant_traits AS (
    SELECT
        *
    FROM int_18_participant_traits
    /* 
      BUSINESS FILTER LOGIC:
      Ensures 1:1 uniqueness per participant per trait in a single match 
      in case overlapping ingestion windows re-deliver existing entries.
    */
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY match_id, puuid, trait_id 
        ORDER BY ingested_at DESC, loaded_at DESC
    ) = 1
),

add_patch_version AS (
    SELECT
        dpt.*,
        COALESCE(p.patch_version, 'Unknown') AS patch_version
    FROM deduplicate_participant_traits dpt
    /* 
      BUSINESS JOIN LOGIC:
      Maps participant match records to the active game patch version 
      based on the match starting timestamp (game_datetime).
    */
    LEFT JOIN {{ ref('tft_patch_version') }} p 
        ON dpt.game_datetime >= p.patch_release_utc
        AND dpt.game_datetime < p.patch_end_utc
),

join_trait_tiers_dimension AS (
    SELECT
        apv.match_id,
        apv.game_datetime,
        apv.puuid,
        apv.placement,
        COALESCE(dtt.trait_sk, MD5(apv.trait_id))   AS trait_sk,
        apv.trait_id,
        COALESCE(dtt.tier_sk, 'Unknown')            AS tier_sk,
        COALESCE(dtt.tier_id, 'Unknown')            AS tier_id,
        COALESCE(dtt.tier_version_sk, 'Unknown')    AS tier_version_sk,
        apv.tier_current,
        apv.tier_total,
        apv.num_units,
        apv.style,
        apv.patch_version,
        apv.ingested_at,
        apv.loaded_at
    FROM add_patch_version apv
    /* 
      BUSINESS JOIN LOGIC:
      Directly joins with the SCD Type 2 trait tiers dimension on trait_id, 
      the active level (tier_current = tier_level), and the specific game patch 
      to retrieve versioned and surrogate keys.
    */
    LEFT JOIN {{ ref('dim_18_traits_tiers') }} dtt
        ON apv.trait_id = dtt.trait_id
        AND apv.tier_current = dtt.tier_level
        AND apv.patch_version = dtt.patch_version
)

SELECT 
    match_id,
    game_datetime,
    puuid,
    placement,
    trait_sk,
    trait_id,
    tier_sk,
    tier_id,
    tier_version_sk,
    tier_current,
    tier_total,
    num_units,
    style,
    patch_version,
    ingested_at,
    loaded_at
FROM join_trait_tiers_dimension