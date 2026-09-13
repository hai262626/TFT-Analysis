{{ config(
    materialized='table',
    schema='agg_matches'
) }}

WITH units_base AS (
    SELECT
        match_id,
        puuid,
        match_id || '_' || puuid AS participant_id,
        placement,
        champion_id,
        champion_sk,
        unit_index,
        unit_tier,
        unit_rarity,
        num_items,
        sorted_items,
        patch_version
    FROM {{ ref('fct_18_participant_units') }}
    WHERE patch_version != 'Unknown'
),

-- 1. Extract offensive component weights from dimensional static catalog (CSV Seed)
equipment_scoring AS (
    SELECT
        equipment_id,
        (
            CASE 
                WHEN component_1 ILIKE ANY ('%BFSword%', '%NeedlesslyLargeRod%', '%RecurveBow%', '%SparringGloves%', '%TearOfTheGoddess%') THEN 1 
                ELSE 0 
            END +
            CASE 
                WHEN component_2 ILIKE ANY ('%BFSword%', '%NeedlesslyLargeRod%', '%RecurveBow%', '%SparringGloves%', '%TearOfTheGoddess%') THEN 1 
                ELSE 0 
            END
        ) AS offensive_components_count
    FROM {{ ref('dim_18_equipments') }}
),

-- 2. Explode item arrays in an isolated CTE to avoid Snowflake lateral join-side limitations
unit_items_exploded AS (
    SELECT
        ub.match_id,
        ub.puuid,
        ub.champion_id,
        ub.unit_index,
        itm.value::STRING AS item_id
    FROM units_base ub,
    TABLE(FLATTEN(input => ub.sorted_items)) itm
    WHERE ub.num_items >= 2
),

unit_item_offensive_score AS (
    SELECT
        uie.match_id,
        uie.puuid,
        uie.champion_id,
        uie.unit_index,
        COALESCE(SUM(eq.offensive_components_count), 0) AS total_offensive_components
    FROM unit_items_exploded uie
    LEFT JOIN equipment_scoring eq
        ON uie.item_id = eq.equipment_id
    GROUP BY 
        uie.match_id, 
        uie.puuid, 
        uie.champion_id, 
        uie.unit_index
),

-- 3. Identify Primary Carry (#1) and Secondary Core (#2) with deterministic Alphabetical tie-breaking
ranked_participant_cores AS (
    SELECT
        ub.match_id,
        ub.puuid,
        ub.participant_id,
        ub.champion_id,
        ub.champion_sk,
        ub.unit_tier,
        ub.unit_rarity,
        ROW_NUMBER() OVER (
            PARTITION BY ub.match_id, ub.puuid 
            ORDER BY 
                ub.num_items DESC,                      -- 1. Primary priority: Item count
                os.total_offensive_components DESC,     -- 2. Damage bias: Offensive components over defensive
                ub.unit_tier DESC,                      -- 3. Star level
                ub.unit_rarity DESC,                    -- 4. Cost rarity
                ub.champion_id ASC                      -- 5. Deterministic tie-breaker: Lexicographical champion order
        ) AS core_rank
    FROM units_base ub
    INNER JOIN unit_item_offensive_score os
        ON ub.match_id = os.match_id
       AND ub.puuid = os.puuid
       AND ub.champion_id = os.champion_id
       AND ub.unit_index = os.unit_index
    WHERE ub.num_items >= 2
),

-- 4. Identify primary activated trait milestone
find_primary_trait AS (
    SELECT
        match_id,
        puuid,
        trait_id,
        num_units || '_' || trait_id AS trait_signature,
        ROW_NUMBER() OVER (
            PARTITION BY match_id, puuid 
            ORDER BY 
                num_units DESC,           -- Deepest activation tier
                style DESC,               -- Highest tier style badge
                tier_current DESC,        -- Active tier milestone
                trait_id ASC              -- Deterministic alphabetical order
        ) AS trait_rank
    FROM {{ ref('fct_18_participant_traits') }}
    WHERE style > 0
),

-- 5. Extract unique participants along with match metadata
participant_base AS (
    SELECT DISTINCT 
        participant_id, 
        match_id, 
        puuid, 
        patch_version, 
        placement 
    FROM units_base
),

-- 6. Stitch together participant-level tactical profiles
final_participant_comp_tags AS (
    SELECT
        pb.participant_id,
        pb.match_id,
        pb.puuid,
        pb.patch_version,
        pb.placement,
        fp.level                                AS end_level,

        -- Composition Identity Tag
        COALESCE(pt.trait_signature, 'NoTrait') || '__' || 
        COALESCE(c1.champion_id, 'NoCarry')     AS comp_key,

        -- Primary Trait Milestone
        COALESCE(pt.trait_signature, 'NoTrait') AS primary_trait,

        -- Primary Carry (#1 Core) Profile
        COALESCE(c1.champion_id, 'NoCarry')     AS main_carry,
        COALESCE(c1.champion_sk, '-1')          AS main_carry_sk,
        COALESCE(c1.unit_tier, 0)               AS main_carry_tier,
        COALESCE(c1.unit_rarity, 0)             AS main_carry_rarity,

        -- Secondary Core (#2 Core) Profile
        COALESCE(c2.champion_id, 'None')        AS secondary_core,
        COALESCE(c2.champion_sk, '-1')          AS secondary_core_sk,
        COALESCE(c2.unit_tier, 0)               AS secondary_core_tier,
        COALESCE(c2.unit_rarity, 0)             AS secondary_core_rarity

    FROM participant_base pb
    INNER JOIN {{ ref('fct_18_participants') }} fp
        ON pb.match_id = fp.match_id
       AND pb.puuid = fp.puuid
    LEFT JOIN find_primary_trait pt 
        ON pb.match_id = pt.match_id 
       AND pb.puuid = pt.puuid 
       AND pt.trait_rank = 1
    LEFT JOIN ranked_participant_cores c1 
        ON pb.match_id = c1.match_id 
       AND pb.puuid = c1.puuid 
       AND c1.core_rank = 1
    LEFT JOIN ranked_participant_cores c2 
        ON pb.match_id = c2.match_id 
       AND pb.puuid = c2.puuid 
       AND c2.core_rank = 2
)

SELECT
    participant_id,
    match_id,
    puuid,
    patch_version,
    placement,
    end_level,
    comp_key,
    primary_trait,
    main_carry,
    main_carry_sk,
    main_carry_tier,
    main_carry_rarity,
    secondary_core,
    secondary_core_sk,
    secondary_core_tier,
    secondary_core_rarity
FROM final_participant_comp_tags
ORDER BY 
    match_id, 
    placement ASC