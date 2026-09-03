{{config(
    materialized='table',
    schema='staging_info'
) }}

WITH raw_items AS (
    SELECT 
        *
    FROM {{source('raw_data', 'raw_tft_items')}}
    
),

select_appropriate_columns AS (
    SELECT
        -- 1. Primary Identifiers
        raw_payload:apiName::STRING                     AS item_id,
        raw_payload:name::STRING                        AS item_name_raw,

        -- 2. Business Classifications & Flags
        raw_payload:isAugment::BOOLEAN                  AS item_is_augment,
        raw_payload:unique::BOOLEAN                     AS item_unique,
        CASE
            WHEN raw_payload:isAugment::BOOLEAN = TRUE 
                 OR raw_payload:icon::STRING ILIKE '%augments%'      THEN 'Augment'
            WHEN raw_payload:icon::STRING ILIKE '%wands%'             THEN 'Wand'
            WHEN raw_payload:apiName::STRING ILIKE '%Artifact%' THEN 'Artifact'
            WHEN raw_payload:apiName::STRING ILIKE '%Emblem%' THEN 'Emblem'
            WHEN raw_payload:apiName::STRING ILIKE '%Radiant%' THEN 'RadiantItem'
            WHEN raw_payload:apiName::STRING ILIKE '%Component%' THEN 'Component'
            WHEN raw_payload:apiName::STRING ILIKE '%Consumable%' THEN 'Consumable'
            WHEN raw_payload:icon::STRING ILIKE '%items%'              THEN 'CompleteItem'
            ELSE 'Unknown'
        END                                             AS item_category,

        -- 3. Clean Text & Display
        TRIM(
            REGEXP_REPLACE(
                REGEXP_REPLACE(raw_payload:desc::STRING, '<[^>]+>|%i:[^%]+%', ' '),
                '[[:space:]]+', 
                ' '
            )
        )                                               AS item_description,
        raw_payload:icon::STRING                        AS icon_path,

        -- 4. Semi-structured Attributes (Correct Data Types)
        raw_payload:effects                             AS item_effects,             
        raw_payload:composition::ARRAY                  AS item_composition,         
        raw_payload:associatedTraits::ARRAY             AS item_associated_traits,   
        raw_payload:incompatibleTraits::ARRAY           AS item_incompatible_traits, 
        raw_payload:"from"::ARRAY                       AS item_from,                

        -- 5. Audit Metadata Timestamps
        CAST(ingested_at AS TIMESTAMP_NTZ)              AS ingested_at,
        CAST(loaded_at AS TIMESTAMP_NTZ)                AS loaded_at

    FROM raw_items
    WHERE raw_payload:apiName::STRING LIKE 'DA_%'
)

SELECT 
    item_id,
    item_name_raw,
    item_is_augment,
    item_unique,
    item_category,
    item_description,
    icon_path,
    item_effects,
    item_composition,
    item_associated_traits,
    item_incompatible_traits,
    item_from,
    ingested_at,
    loaded_at
FROM select_appropriate_columns