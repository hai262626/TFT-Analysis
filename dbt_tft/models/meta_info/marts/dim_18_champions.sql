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
    LEFT JOIN {{ ref('tft_patch_version') }} p 
        ON sc.dbt_valid_from >= p.patch_release_utc
        AND sc.dbt_valid_from < p.patch_end_utc
),

hashing_champion_keys AS (
    SELECT
        md5(CONCAT(champion_id, '_', dbt_valid_from)) AS champion_version_sk,
        md5(champion_id)                             AS champion_sk,
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
    FROM add_patch_version
),

add_tier_zero AS (
    SELECT
        '-1'                                           AS champion_version_sk,
        '-1'                                           AS champion_sk,
        0                                              AS set_number,
        'Unknown'                                      AS champion_id,
        'Unknown'                                      AS champion_name,
        0                                              AS cost,
        NULL                                           AS first_trait,
        NULL                                           AS second_trait,
        NULL                                           AS third_trait,
        0                                              AS base_hp,
        0                                              AS base_armor,
        0                                              AS base_magic_resist,
        0                                              AS base_attack_damage,
        0                                              AS base_attack_speed,
        0                                              AS crit_chance,
        0                                              AS crit_multiplier,
        0                                              AS attack_range,
        0                                              AS initial_mana,
        0                                              AS max_mana,
        NULL                                           AS champion_ability,
        NULL                                           AS champion_ability_description,
        'Unknown'                                      AS patch_version,
        '1900-01-01 00:00:00.000000'::TIMESTAMP_NTZ    AS dbt_valid_from,
        '9999-12-31 23:59:59.999999'::TIMESTAMP_NTZ    AS dbt_valid_to,
        '1900-01-01 00:00:00.000000'::TIMESTAMP_NTZ    AS ingested_at,
        '1900-01-01 00:00:00.000000'::TIMESTAMP_NTZ    AS loaded_at
),

union_with_tier_zero AS (
    SELECT * FROM hashing_champion_keys
    UNION ALL
    SELECT * FROM add_tier_zero
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
FROM union_with_tier_zero

