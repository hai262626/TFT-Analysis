{{config(
    materialized='view',
    schema='int_info'
) }}

WITH stg_traits AS (
    SELECT 
        *
    FROM {{ref('stg_18_traits')}}
    
),

select_appropriate_columns AS (
    SELECT
        set_number,
        trait_id,
        trait_name,
        trait_description,
        ingested_at,
        loaded_at
    FROM stg_traits
)

SELECT * FROM select_appropriate_columns