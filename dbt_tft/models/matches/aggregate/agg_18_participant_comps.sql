{{ config(
    materialized='table',
    schema='mart_matches'
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

-- 1. Patch lobby benchmarks: Compute total unique matches and participants
patch_benchmarks AS (
    SELECT
        patch_version,
        COUNT(DISTINCT match_id)       AS total_matches,
        COUNT(DISTINCT participant_id) AS total_participants
    FROM units_base
    GROUP BY patch_version
),

-- 2. Extract offensive component weights from dimensional catalog
equipment_scoring AS (
    SELECT
        equipment_id,
        patch_version,
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
    WHERE equipment_sk != '-1'
),

-- 3. Explode item arrays in an isolated CTE to avoid Snowflake lateral join-side limitations
unit_items_exploded AS (
    SELECT
        ub.match_id,
        ub.puuid,
        ub.champion_id,
        ub.unit_index,
        ub.patch_version,
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
        AND uie.patch_version = eq.patch_version
    GROUP BY 
        uie.match_id, 
        uie.puuid, 
        uie.champion_id, 
        uie.unit_index
),

-- 4. Identify Primary Carry (#1) and Secondary Core (#2) with deterministic Alphabetical tie-breaking
ranked_participant_cores AS (
    SELECT
        ub.match_id,
        ub.puuid,
        ub.participant_id,
        ub.champion_id,
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

-- 5. Identify primary activated trait milestone
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

-- 6. Construct singular composition key and map participant end-game level
participant_comp_tags AS (
    SELECT
        ub.participant_id,
        ub.match_id,
        ub.puuid,
        ub.patch_version,
        ub.placement,
        fp.level                                AS end_level,
        COALESCE(pt.trait_signature, 'NoTrait') AS primary_trait,
        COALESCE(c1.champion_id, 'NoCarry')     AS main_carry,
        COALESCE(c1.unit_tier, 0)               AS main_carry_tier,
        COALESCE(c1.unit_rarity, 0)             AS main_carry_rarity,
        COALESCE(c2.champion_id, 'None')        AS secondary_core,
        COALESCE(c2.unit_tier, 0)               AS secondary_core_tier,
        COALESCE(c2.unit_rarity, 0)             AS secondary_core_rarity,
        
        -- Composition identifier anchored solely on Primary Trait and Main Carry
        COALESCE(pt.trait_signature, 'NoTrait') || '__' || 
        COALESCE(c1.champion_id, 'NoCarry')     AS comp_key
    FROM (
        SELECT DISTINCT 
            participant_id, 
            match_id, 
            puuid, 
            patch_version, 
            placement 
        FROM units_base
    ) ub
    INNER JOIN {{ ref('fct_18_participants') }} fp
        ON ub.match_id = fp.match_id
       AND ub.puuid = fp.puuid
    LEFT JOIN find_primary_trait pt 
        ON ub.match_id = pt.match_id 
       AND ub.puuid = pt.puuid 
       AND pt.trait_rank = 1
    LEFT JOIN ranked_participant_cores c1 
        ON ub.match_id = c1.match_id 
       AND ub.puuid = c1.puuid 
       AND c1.core_rank = 1
    LEFT JOIN ranked_participant_cores c2 
        ON ub.match_id = c2.match_id 
       AND ub.puuid = c2.puuid 
       AND c2.core_rank = 2
),

-- 7. Empirical rate aggregation per composition archetype
comp_raw_aggregates AS (
    SELECT
        pct.patch_version,
        pct.comp_key,
        pct.primary_trait,
        pct.main_carry,
        MAX(pct.main_carry_rarity)                         AS main_carry_rarity,
        ROUND(AVG(pct.end_level), 2)                       AS avg_end_level,
        COUNT(DISTINCT pct.participant_id)                 AS unique_players_picked,
        COUNT(DISTINCT pct.match_id)                       AS unique_matches_picked,
        ROUND(AVG(pct.placement), 4)                       AS avg_placement,
        COUNT(CASE WHEN pct.placement <= 4 THEN 1 END)     AS top4_count,
        COUNT(CASE WHEN pct.placement = 1 THEN 1 END)      AS win_count,

        -- Standardized Popularity Rates matching Items Mart Schema
        ROUND(
            COUNT(DISTINCT pct.participant_id) * 100.0 / NULLIF(bm.total_participants, 0),
            4
        ) AS player_popularity_pct,
        ROUND(
            COUNT(DISTINCT pct.match_id) * 100.0 / NULLIF(bm.total_matches, 0),
            4
        ) AS match_popularity_pct,

        ROUND(
            COUNT(CASE WHEN pct.placement <= 4 THEN 1 END) * 100.0 / NULLIF(COUNT(DISTINCT pct.participant_id), 0),
            4
        ) AS top4_rate_pct,
        ROUND(
            COUNT(CASE WHEN pct.placement = 1 THEN 1 END) * 100.0 / NULLIF(COUNT(DISTINCT pct.participant_id), 0),
            4
        ) AS win_rate_pct,

        bm.total_matches,
        bm.total_participants
    FROM participant_comp_tags pct
    INNER JOIN patch_benchmarks bm
        ON pct.patch_version = bm.patch_version
    WHERE pct.comp_key NOT LIKE '%NoCarry%'
      AND pct.comp_key NOT LIKE '%NoTrait%'
    GROUP BY 
        pct.patch_version, 
        pct.comp_key, 
        pct.primary_trait, 
        pct.main_carry,
        bm.total_matches,
        bm.total_participants
    HAVING COUNT(DISTINCT pct.participant_id) >= 20
),

-- 8. STATISTICAL DISTRIBUTION: Calculate Mean (μ) and Population StdDev (σ) per patch
patch_statistical_distribution AS (
    SELECT
        patch_version,
        AVG(avg_placement)                        AS mean_placement,
        STDDEV_POP(avg_placement)                 AS std_placement,
        AVG(top4_rate_pct)                        AS mean_top4,
        STDDEV_POP(top4_rate_pct)                 AS std_top4,
        AVG(win_rate_pct)                         AS mean_win,
        STDDEV_POP(win_rate_pct)                  AS std_win,
        AVG(LN(1 + player_popularity_pct))        AS mean_log_popularity,
        STDDEV_POP(LN(1 + player_popularity_pct)) AS std_log_popularity
    FROM comp_raw_aggregates
    GROUP BY patch_version
),

-- 9. Standardized Gaussian Z-Scores & Weighted 40-30-20-10 Composite Scoring
comp_scored AS (
    SELECT
        cra.patch_version,
        cra.comp_key,
        cra.primary_trait,
        cra.main_carry,
        cra.main_carry_rarity,
        cra.avg_end_level,
        ROUND(cra.player_popularity_pct, 2) AS player_popularity_pct,
        ROUND(cra.match_popularity_pct, 2)  AS match_popularity_pct,
        ROUND(cra.avg_placement, 2)         AS avg_placement,
        ROUND(cra.top4_rate_pct, 2)         AS top4_rate_pct,
        ROUND(cra.win_rate_pct, 2)          AS win_rate_pct,
        cra.unique_players_picked,
        cra.unique_matches_picked,
        cra.total_matches,
        cra.total_participants,

        -- Standardized Gaussian components
        ROUND((psd.mean_placement - cra.avg_placement) / NULLIF(psd.std_placement, 0), 3)                   AS z_placement,
        ROUND((cra.top4_rate_pct - psd.mean_top4) / NULLIF(psd.std_top4, 0), 3)                             AS z_top4,
        ROUND((cra.win_rate_pct - psd.mean_win) / NULLIF(psd.std_win, 0), 3)                                AS z_win,
        ROUND((LN(1 + cra.player_popularity_pct) - psd.mean_log_popularity) / NULLIF(psd.std_log_popularity, 0), 3) AS z_popularity,

        -- STANDARDIZED COMPOSITE FORMULA: 40% Top 4 + 30% Inverted Placement + 20% Popularity + 10% Win Rate
        ROUND(
            (0.40 * ((cra.top4_rate_pct - psd.mean_top4) / NULLIF(psd.std_top4, 0))) +
            (0.30 * ((psd.mean_placement - cra.avg_placement) / NULLIF(psd.std_placement, 0))) +
            (0.20 * ((LN(1 + cra.player_popularity_pct) - psd.mean_log_popularity) / NULLIF(psd.std_log_popularity, 0))) +
            (0.10 * ((cra.win_rate_pct - psd.mean_win) / NULLIF(psd.std_win, 0))),
            3
        ) AS composite_z_score

    FROM comp_raw_aggregates cra
    INNER JOIN patch_statistical_distribution psd
        ON cra.patch_version = psd.patch_version
),

-- 10. Flag high-roll 3-star 4/5-cost outliers to ensure showcase sanity
highroll_participants AS (
    SELECT DISTINCT
        match_id,
        puuid
    FROM units_base
    WHERE unit_rarity IN (3, 4)
      AND unit_tier >= 3
),

-- 11. Associate qualified match boards to composition keys
board_candidates AS (
    SELECT
        pct.patch_version,
        pct.comp_key,
        pct.placement,
        fp.units AS showcase_board_payload,
        
        IFF(hp.puuid IS NOT NULL, TRUE, FALSE) AS has_highroll_4_5_cost_3star,

        pct.main_carry_rarity,
        pct.main_carry_tier,
        pct.secondary_core,
        pct.secondary_core_rarity,
        pct.secondary_core_tier

    FROM participant_comp_tags pct
    INNER JOIN comp_scored cs
        ON pct.patch_version = cs.patch_version 
       AND pct.comp_key = cs.comp_key
    INNER JOIN {{ ref('fct_18_participants') }} fp
        ON pct.match_id = fp.match_id 
       AND pct.puuid = fp.puuid
    LEFT JOIN highroll_participants hp
        ON pct.match_id = hp.match_id
       AND pct.puuid = hp.puuid
),

-- 12. Select exemplar showcase board matching realistic player behavior
best_board_selector AS (
    SELECT
        patch_version,
        comp_key,
        showcase_board_payload,
        ROW_NUMBER() OVER (
            PARTITION BY patch_version, comp_key 
            ORDER BY 
                CASE 
                    WHEN has_highroll_4_5_cost_3star = TRUE THEN 3
                    
                    -- Reroll archetypes (1, 2, 3-cost)
                    WHEN main_carry_rarity IN (0, 1, 2) THEN
                        CASE 
                            WHEN main_carry_tier = 3 
                             AND (
                                 (secondary_core_rarity IN (0, 1, 2) AND secondary_core_tier = 3)
                                 OR (secondary_core_rarity IN (3, 4) AND secondary_core_tier <= 2)
                                 OR secondary_core = 'None'
                             ) THEN 1
                            ELSE 2
                        END

                    -- Fast 8/9 standard archetypes (4, 5-cost)
                    WHEN main_carry_rarity IN (3, 4) THEN
                        CASE 
                            WHEN main_carry_tier = 2 
                             AND (secondary_core_tier <= 2 OR secondary_core = 'None') THEN 1
                            ELSE 2
                        END

                    ELSE 2
                END ASC,

                placement ASC,
                ARRAY_SIZE(showcase_board_payload) DESC
        ) AS rn
    FROM board_candidates
),

-- 13. Final CTE consolidating archetype classification, rank assignments, and schema projections
final_comp_showcase AS (
    SELECT
        cs.patch_version,
        DENSE_RANK() OVER (
            PARTITION BY cs.patch_version 
            ORDER BY cs.composite_z_score DESC
        ) AS comp_tier_rank,

        CASE 
            WHEN cs.composite_z_score >= 1.28 THEN 'S-Tier'
            WHEN cs.composite_z_score >= 0.52 THEN 'A-Tier'
            WHEN cs.composite_z_score >= -0.25 THEN 'B-Tier'
            ELSE 'C-Tier'
        END AS tier_label,

        -- Tactical Archetype recognition based on cost tier and leveling curve
        CASE
            WHEN cs.main_carry_rarity = 4 THEN
                CASE 
                    WHEN cs.avg_end_level >= 8.8 THEN 'Fast 9 (Exotics / Legendary)'
                    ELSE 'Fast 8 (5-Cost Highroll)'
                END
            WHEN cs.main_carry_rarity = 3 THEN
                CASE
                    WHEN cs.avg_end_level >= 8.8 THEN 'Fast 9 (4-Cost Capstone)'
                    ELSE 'Standard (Fast 8)'
                END
            WHEN cs.main_carry_rarity = 2 THEN '3-Cost Reroll (Level 7)'
            WHEN cs.main_carry_rarity = 1 THEN '2-Cost Reroll (Level 6)'
            WHEN cs.main_carry_rarity = 0 THEN '1-Cost Reroll (Level 5)'
            ELSE 'Standard Flex'
        END AS comp_archetype,

        cs.comp_key,
        cs.primary_trait,
        cs.main_carry,
        cs.avg_end_level,

        -- Meta Scoring & Rates (Standardized naming matching Items Mart)
        cs.composite_z_score,
        cs.player_popularity_pct,
        cs.match_popularity_pct,
        cs.avg_placement,
        cs.top4_rate_pct,
        cs.win_rate_pct,

        -- Detailed Z-Scores
        cs.z_placement,
        cs.z_top4,
        cs.z_win,
        cs.z_popularity,

        -- Context Counters
        cs.unique_players_picked,
        cs.unique_matches_picked,
        cs.total_matches,
        cs.total_participants,

        bbs.showcase_board_payload AS exemplar_board_units
    FROM comp_scored cs
    INNER JOIN best_board_selector bbs
        ON cs.patch_version = bbs.patch_version
       AND cs.comp_key = bbs.comp_key
       AND bbs.rn = 1
)

-- Final SELECT projecting standardized attributes directly
SELECT
    patch_version,
    comp_tier_rank,
    tier_label,
    comp_archetype,
    comp_key,
    primary_trait,
    main_carry,
    avg_end_level,
    composite_z_score,
    player_popularity_pct,
    match_popularity_pct,
    avg_placement,
    top4_rate_pct,
    win_rate_pct,
    z_placement,
    z_top4,
    z_win,
    z_popularity,
    unique_players_picked,
    unique_matches_picked,
    total_matches,
    total_participants,
    exemplar_board_units
FROM final_comp_showcase
ORDER BY 
    patch_version DESC, 
    comp_tier_rank ASC