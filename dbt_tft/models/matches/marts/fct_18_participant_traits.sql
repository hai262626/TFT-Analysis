{{ config(
    materialized='incremental',
    schema='mart_matches',
    unique_key='match_id',
    incremental_strategy='delete+insert',
    on_schema_change='sync_all_columns'
)}}

WITH int_18_participant_traits AS (
    SELECT
        match_id,
        game_datetime,
        puuid,
        placement,
        trait_name,
        num_units,
        style,
        tier_current,
        tier_total,
        ingested_at,
        loaded_at
    FROM {{ ref('int_18_participant_traits') }}
    {% if is_incremental() %}
        WHERE ingested_at > (
            SELECT DATEADD(day, -3, MAX(target.ingested_at)) 
            FROM {{ this }} AS target
        )
    {% endif %}
),

add_patch_version AS (
    SELECT
        i18pt.*,
        COALESCE(p.patch_version, 'Unknown') AS patch_version
    FROM int_18_participant_traits i18pt
    LEFT JOIN  {{ ref('tft_patch_version') }} p 
        ON i18pt.game_datetime >= p.patch_release_utc
        AND i18pt.game_datetime < p.patch_end_utc
),

hash_trait_id AS (
    SELECT
        *,
        MD5(trait_name) AS trait_sk
    FROM add_patch_version
),

take_tier_id_and_tier_sk AS (
    SELECT
        hti.*,
        COALESCE(dtt.tier_id, 'Unknown') AS tier_id,
        COALESCE(dtt.tier_sk, 'Unknown') AS tier_sk
    FROM hash_trait_id hti
    LEFT JOIN {{ ref('dim_18_traits_tiers') }} dtt
        ON hti.trait_name = dtt.trait_id
        AND hti.tier_current = dtt.tier_level
        AND hti.patch_version = dtt.patch_version
)

SELECT 
    match_id,
    game_datetime,
    puuid,
    placement,
    trait_sk,
    trait_name,
    tier_sk,
    tier_id,
    tier_current,
    tier_total,
    num_units,
    style,
    patch_version,
    ingested_at,
    loaded_at
FROM take_tier_id_and_tier_sk