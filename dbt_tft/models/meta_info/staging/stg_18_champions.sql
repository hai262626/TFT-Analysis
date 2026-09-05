{{ config(
    materialized='view',
    schema='staging_info'
) }}

WITH raw_champions AS (
    SELECT 
        *
    FROM {{ source('raw_data', 'raw_tft_champions') }}
),

select_appropriate_columns AS (
    SELECT
        -- Dimension Keys & Metadata
        raw_payload:_set_number::INT                AS set_number,
        raw_payload:characterName::STRING           AS champion_id,
        raw_payload:name::STRING                    AS champion_name,
        raw_payload:cost::INT                       AS cost,
        
        -- Traits (De-nested from array slots)
        raw_payload:traits[0]::STRING                   AS first_trait,
        COALESCE(raw_payload:traits[1]::STRING, 'None') AS second_trait,
        COALESCE(raw_payload:traits[2]::STRING, 'None') AS third_trait,

        -- Defensive Base Stats
        raw_payload:stats:hp::INT                   AS base_hp,
        raw_payload:stats:armor::INT                AS base_armor,
        raw_payload:stats:magicResist::INT          AS base_magic_resist,

        -- Offensive Base Stats
        raw_payload:stats:damage::INT                       AS base_attack_damage,
        ROUND(raw_payload:stats:attackSpeed::FLOAT, 2)      AS base_attack_speed,
        ROUND(raw_payload:stats:critChance::FLOAT, 4)       AS crit_chance,
        ROUND(raw_payload:stats:critMultiplier::FLOAT, 4)   AS crit_multiplier,
        raw_payload:stats:range::INT                        AS attack_range,

        -- Mana Mechanics
        raw_payload:stats:initialMana::INT          AS initial_mana,
        raw_payload:stats:mana::INT                 AS max_mana,

        -- Ability Information
        raw_payload:ability:name::STRING            AS champion_ability,
        raw_payload:ability:desc::STRING            AS champion_ability_description,
        raw_payload:ability:variables::ARRAY        AS variables,

        -- Audit Metadata Timestamps
        CAST(ingested_at AS TIMESTAMP_NTZ)          AS ingested_at,
        CAST(loaded_at AS TIMESTAMP_NTZ)            AS loaded_at

    FROM raw_champions
    /* 
      BUSINESS FILTER LOGIC:
      1. set_number = 18: Restricts scope exclusively to Set 18 active season data.
      2. champion_id LIKE 'DA_%': Filters out legacy test assets, summonable minions, and training dummies that do not belong to the playable champion pool.
    */
    WHERE set_number = 18
        AND champion_id LIKE 'DA_%'
),

clean_description AS (
    SELECT
        *,
        -- Strips rich-text tags (e.g., <magicDamage>, <physicalDamage>), internal game formatting codes (%i:...%), 
        -- and cleans up multiple spaces/newlines into a readable plain string.
        TRIM(
            REGEXP_REPLACE(
                REGEXP_REPLACE(
                    champion_ability_description,
                    '<[^>]+>|%i:[^%]+%|(\\\\n|\\n|[\r\n])+', 
                    ' '
                ),
                '[[:space:]]+', 
                ' '
            )
        ) AS champion_ability_description_cleaned
    FROM select_appropriate_columns
)

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
    champion_ability_description_cleaned AS champion_ability_description,
    ingested_at,
    loaded_at
FROM clean_description