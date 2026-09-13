{{ config(
    materialized='table',
    schema='agg_matches'
) }}

WITH base_comps AS (
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
    FROM {{ ref('agg_18_int_defining_comps') }}
    WHERE patch_version != 'Unknown'
      AND comp_key NOT LIKE '%NoCarry%'
      AND comp_key NOT LIKE '%NoTrait%'
),

-- 1. Patch lobby benchmarks: Compute total unique matches and participants per patch
patch_benchmarks AS (
    SELECT
        patch_version,
        COUNT(DISTINCT match_id)       AS total_matches,
        COUNT(DISTINCT participant_id) AS total_participants
    FROM base_comps
    GROUP BY patch_version
),

-- 2. Empirical rate aggregation per composition archetype
comp_raw_aggregates AS (
    SELECT
        bc.patch_version,
        bc.comp_key,
        bc.primary_trait,
        bc.main_carry,
        MAX(bc.main_carry_rarity)                                          AS main_carry_rarity,
        ROUND(AVG(bc.end_level), 2)                                        AS avg_end_level,
        COUNT(DISTINCT bc.participant_id)                                  AS unique_players_picked,
        COUNT(DISTINCT bc.match_id)                                        AS unique_matches_picked,
        ROUND(AVG(bc.placement), 4)                                        AS avg_placement,
        COUNT(CASE WHEN bc.placement <= 4 THEN 1 END)                      AS top4_count,
        COUNT(CASE WHEN bc.placement = 1 THEN 1 END)                       AS win_count,

        -- Standardized Popularity Rates matching Items & Traits Mart Schema
        ROUND(
            COUNT(DISTINCT bc.participant_id) * 100.0 / NULLIF(bm.total_participants, 0),
            4
        ) AS player_popularity_pct,
        ROUND(
            COUNT(DISTINCT bc.match_id) * 100.0 / NULLIF(bm.total_matches, 0),
            4
        ) AS match_popularity_pct,

        ROUND(
            COUNT(CASE WHEN bc.placement <= 4 THEN 1 END) * 100.0 / NULLIF(COUNT(DISTINCT bc.participant_id), 0),
            4
        ) AS top4_rate_pct,
        ROUND(
            COUNT(CASE WHEN bc.placement = 1 THEN 1 END) * 100.0 / NULLIF(COUNT(DISTINCT bc.participant_id), 0),
            4
        ) AS win_rate_pct,

        bm.total_matches,
        bm.total_participants
    FROM base_comps bc
    INNER JOIN patch_benchmarks bm
        ON bc.patch_version = bm.patch_version
    GROUP BY 
        bc.patch_version, 
        bc.comp_key, 
        bc.primary_trait, 
        bc.main_carry,
        bm.total_matches,
        bm.total_participants
    HAVING COUNT(DISTINCT bc.participant_id) >= 20
),

-- 3. STATISTICAL DISTRIBUTION: Calculate Mean (μ) and Population StdDev (σ) per patch
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

-- 4. Standardized Gaussian Z-Scores & Weighted 40-30-20-10 Composite Scoring
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

-- 5. Flag high-roll 3-star 4/5-cost outliers to prevent abnormal showcase boards
highroll_participants AS (
    SELECT DISTINCT
        match_id,
        puuid
    FROM {{ ref('fct_18_participant_units') }}
    WHERE unit_rarity IN (3, 4)
      AND unit_tier >= 3
),

-- 6. Associate qualified match boards to qualified composition keys
board_candidates AS (
    SELECT
        bc.patch_version,
        bc.comp_key,
        bc.placement,
        fp.units AS showcase_board_payload,
        
        IFF(hp.puuid IS NOT NULL, TRUE, FALSE) AS has_highroll_4_5_cost_3star,

        bc.main_carry_rarity,
        bc.main_carry_tier,
        bc.secondary_core,
        bc.secondary_core_rarity,
        bc.secondary_core_tier

    FROM base_comps bc
    INNER JOIN comp_scored cs
        ON bc.patch_version = cs.patch_version 
       AND bc.comp_key = cs.comp_key
    INNER JOIN {{ ref('fct_18_participants') }} fp
        ON bc.match_id = fp.match_id 
       AND bc.puuid = fp.puuid
    LEFT JOIN highroll_participants hp
        ON bc.match_id = hp.match_id
       AND bc.puuid = hp.puuid
),

-- 7. Select exemplar showcase board matching realistic player behavior
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

-- 8. Final CTE consolidating archetype classification, rank assignments, and schema projections
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

        -- Meta Scoring & Rates (Standardized naming matching Items & Traits Mart)
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