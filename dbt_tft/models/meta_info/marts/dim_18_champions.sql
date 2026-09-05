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
        COALESCE(dbt_valid_to, '9999-12-31 23:59:59.999999') AS dbt_valid_to
    FROM {{ ref('stg_18_champions_snapshot') }}
),

add_patch_version AS (
    SELECT
        sc.*,
        COALESCE(p.patch_version, 'Unknown') AS patch_version
    FROM snapshot_champions sc
    LEFT JOIN  {{ ref('tft_patch_version') }} p 
        ON sc.dbt_valid_from >= p.patch_release_utc
        AND sc.dbt_valid_from < p.patch_end_utc
),

hashing_champion_id AS (
    SELECT
        *,
        MD5(champion_id) AS champion_sk
    FROM add_patch_version
)

SELECT
    set_number,
    champion_sk,
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
    dbt_valid_from,
    dbt_valid_to,
    patch_version
FROM hashing_champion_id
