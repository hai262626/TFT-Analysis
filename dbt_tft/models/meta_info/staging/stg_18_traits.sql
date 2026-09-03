{{config(
    materialized='table',
    schema='staging_info'
) }}

WITH raw_traits AS (
    SELECT 
        *
    FROM {{source('raw_data', 'raw_tft_traits')}}
    
),

select_appropriate_columns AS (
    SELECT
        raw_payload:_set_number::INT                AS set_number,
        raw_payload:apiName::STRING                 AS trait_id,
        raw_payload:name::STRING                    AS trait_name,
        raw_payload:desc::STRING                    AS trait_description,
        raw_payload:effects::ARRAY                  AS trait_effects,
        CAST(ingested_at AS TIMESTAMP_NTZ) AS ingested_at,
        CAST(loaded_at AS TIMESTAMP_NTZ) AS loaded_at
    FROM raw_traits
    WHERE set_number = 18
)

SELECT
    set_number,
    trait_id,
    trait_name,
    trait_description,
    trait_effects
FROM select_appropriate_columns