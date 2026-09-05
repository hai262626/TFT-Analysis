{{ config(
    materialized='table',
    schema='mart_info'
) }}

WITH snapshot_champions AS (
    SELECT
        set_number,
        champion_id,
        champion_name,
        cost,
        first_trait,
        second_trait,
        third_trait,
        base_hp,
        base_armor,
        base_magic_resist,
        base_attack_damage,
        base_attack_speed,
        crit_chance,
        crit_multiplier,
        attack_range,
        initial_mana,
        max_mana,
        champion_ability,
        champion_ability_description,
        ingested_at,
        loaded_at,
        dbt_valid_from,
        COALESCE(dbt_valid_to, '9999-12-31 23:59:59.999999'::TIMESTAMP_NTZ) AS dbt_valid_to
    FROM {{ ref('stg_18_champions_snapshot') }}
),

add_patch_version AS (
    SELECT
        sc.*,
        COALESCE(p.patch_version, 'Unknown') AS patch_version
    FROM snapshot_champions sc
    /* 
      BUSINESS JOIN LOGIC:
      Maps each snapshot version of a champion's base stats and traits to its corresponding 
      TFT game patch release window based on when the snapshot record became active (dbt_valid_from).
    */
    LEFT JOIN {{ ref('tft_patch_version') }} p 
        ON sc.dbt_valid_from >= p.patch_release_utc
        AND sc.dbt_valid_from < p.patch_end_utc
),

hashing_champion_keys AS (
    SELECT
        *,
        md5(CONCAT(champion_id, '_', dbt_valid_from)) AS champion_version_sk,
        md5(champion_id)                              AS champion_sk
    FROM add_patch_version
)

SELECT
    champion_version_sk,
    champion_sk,
    set_number,
    champion_id,
    champion_name,
    cost,
    first_trait,
    second_trait,
    third_trait,
    base_hp,
    base_armor,
    base_magic_resist,
    base_attack_damage,
    base_attack_speed,
    crit_chance,
    crit_multiplier,
    attack_range,
    initial_mana,
    max_mana,
    champion_ability,
    champion_ability_description,
    patch_version,
    dbt_valid_from,
    dbt_valid_to,
    ingested_at,
    loaded_at
FROM hashing_champion_keys