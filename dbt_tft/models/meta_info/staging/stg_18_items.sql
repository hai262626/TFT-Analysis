{{ config(
    materialized='view',
    schema='staging_info'
) }}

WITH raw_items AS (
    SELECT 
        *
    FROM {{ source('raw_data', 'raw_tft_items') }}
),

select_appropriate_columns AS (
    SELECT
        -- Primary Identifiers
        raw_payload:apiName::STRING                     AS item_id,
        raw_payload:name::STRING                        AS item_name,

        -- Raw Flags & Attributes for Classification
        raw_payload:isAugment::BOOLEAN                  AS item_is_augment,
        raw_payload:unique::BOOLEAN                     AS item_unique,
        raw_payload:icon::STRING                        AS icon_path,

        -- Raw Description Text
        raw_payload:desc::STRING                        AS item_description_raw,

        -- Semi-structured Attributes
        raw_payload:effects                             AS item_effects,             
        raw_payload:composition::ARRAY                  AS item_composition,         
        raw_payload:associatedTraits::ARRAY             AS item_associated_traits,   
        raw_payload:incompatibleTraits::ARRAY           AS item_incompatible_traits, 
        raw_payload:"from"::ARRAY                       AS item_from,                

        -- Audit Metadata Timestamps
        CAST(ingested_at AS TIMESTAMP_NTZ)              AS ingested_at,
        CAST(loaded_at AS TIMESTAMP_NTZ)                AS loaded_at

    FROM raw_items
    /* 
      BUSINESS FILTER LOGIC:
      raw_payload:apiName LIKE 'DA_%': Filters items, augments, and emblems specific to Set 18, 
      excluding base game generic assets, legacy items from previous sets, and internal test placeholders.
    */
    WHERE raw_payload:apiName::STRING LIKE 'DA_%'
),

add_item_classifications AS (
    SELECT
        *,
        CASE
            WHEN item_is_augment = TRUE 
                 OR icon_path ILIKE '%augments%'       THEN 'Augment'
            WHEN icon_path ILIKE '%wands%'             THEN 'Wand'
            WHEN item_id ILIKE '%Artifact%'            THEN 'Artifact'
            WHEN item_id ILIKE '%Emblem%'              THEN 'Emblem'
            WHEN item_id ILIKE '%Radiant%'             THEN 'RadiantItem'
            WHEN item_id ILIKE '%Component%'           THEN 'Component'
            WHEN item_id ILIKE '%Consumable%'          THEN 'Consumable'
            WHEN icon_path ILIKE '%items%'             THEN 'CompleteItem'
            ELSE 'Unknown'
        END                                            AS item_category
    FROM select_appropriate_columns
),

clean_description AS (
    SELECT
        *,
        TRIM(
            REGEXP_REPLACE(
                REGEXP_REPLACE(
                    item_description_raw, 
                    '<[^>]+>|%i:[^%]+%|(\\\\n|\\n|[\r\n])+', 
                    ' '
                ),
                '[[:space:]]+', 
                ' '
            )
        ) AS item_description
    FROM add_item_classifications
)

SELECT 
    item_id,
    item_name,
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
FROM clean_description