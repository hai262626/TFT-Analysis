{{ config(
    materialized='view',
    schema='staging_info'
) }}

WITH raw_traits AS (
    SELECT 
        *
    FROM {{ source('raw_data', 'raw_tft_traits') }}
),

select_appropriate_columns AS (
    SELECT
        -- Primary Identifiers & Dimension Keys
        raw_payload:_set_number::INT                AS set_number,
        raw_payload:apiName::STRING                 AS trait_id,
        raw_payload:name::STRING                    AS trait_name,

        -- Raw Text & Display Attributes
        raw_payload:desc::STRING                    AS trait_description_raw,

        -- Semi-structured Attributes
        raw_payload:effects::ARRAY                  AS trait_effects,

        -- Audit Metadata Timestamps
        CAST(ingested_at AS TIMESTAMP_NTZ)          AS ingested_at,
        CAST(loaded_at AS TIMESTAMP_NTZ)            AS loaded_at

    FROM raw_traits
    /* 
      BUSINESS FILTER LOGIC:
      set_number = 18: Restricts scope exclusively to Set 18 active season traits, 
      filtering out deprecated trait archetypes from previous sets.
    */
    WHERE set_number = 18
),

clean_description AS (
    SELECT
        *,
        TRIM(
            REGEXP_REPLACE(
                REGEXP_REPLACE(
                    trait_description_raw, 
                    '<[^>]+>|%i:[^%]+%|(\\\\n|\\n|[\r\n])+', 
                    ' '
                ),
                '[[:space:]]+', 
                ' '
            )
        ) AS trait_description
    FROM select_appropriate_columns
)

SELECT
    set_number,
    trait_id,
    trait_name,
    trait_description,
    trait_effects,
    ingested_at,
    loaded_at
FROM clean_description