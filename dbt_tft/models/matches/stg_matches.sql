{{config(
    materialized='table',
    schema='staging_matches'
) }}


WITH source_data AS (
    SELECT raw_payload:set_number::INT AS set_number 
    FROM {{source('raw_data', 'raw_matches')}}
)


SELECT * FROM source_data