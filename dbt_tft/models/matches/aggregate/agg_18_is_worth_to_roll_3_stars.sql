{{ config(
    materialized='table',
    schema='agg_matches'
) }}

WITH base_units AS (
    SELECT
        patch_version,
        champion_id,
        champion_sk,
        unit_rarity,
        unit_tier,
        placement,
        match_id || '_' || puuid AS participant_id
    FROM {{ ref('fct_18_participant_units') }}
    -- BUSINESS RULE: Filter strictly for low-to-mid cost units eligible for reroll strategy (1, 2, 3 cost)
    WHERE unit_rarity IN (0, 1, 2)
      AND patch_version != 'Unknown'
),

-- 1. Aggregate empirical 2-star baseline and 3-star performance metrics
champion_tier_aggregations AS (
    SELECT
        patch_version,
        champion_id,
        MAX(champion_sk) AS champion_sk,
        MAX(unit_rarity) AS unit_rarity,

        COUNT(DISTINCT participant_id) AS total_appearances,

        -- 2-star baseline metrics
        COUNT(CASE WHEN unit_tier = 2 THEN 1 END) AS count_2star,
        ROUND(
            COUNT(CASE WHEN unit_tier = 2 AND placement <= 4 THEN 1 END) * 100.0 
            / NULLIF(COUNT(CASE WHEN unit_tier = 2 THEN 1 END), 0),
            4
        ) AS top4_rate_2star,
        ROUND(
            COUNT(CASE WHEN unit_tier = 2 AND placement = 1 THEN 1 END) * 100.0 
            / NULLIF(COUNT(CASE WHEN unit_tier = 2 THEN 1 END), 0),
            4
        ) AS win_rate_2star,

        -- 3-star performance metrics
        COUNT(CASE WHEN unit_tier = 3 THEN 1 END) AS count_3star,
        ROUND(
            AVG(CASE WHEN unit_tier = 3 THEN placement END), 
            4
        ) AS avg_placement_3star,
        ROUND(
            COUNT(CASE WHEN unit_tier = 3 AND placement <= 4 THEN 1 END) * 100.0 
            / NULLIF(COUNT(CASE WHEN unit_tier = 3 THEN 1 END), 0),
            4
        ) AS top4_rate_3star,
        ROUND(
            COUNT(CASE WHEN unit_tier = 3 AND placement = 1 THEN 1 END) * 100.0 
            / NULLIF(COUNT(CASE WHEN unit_tier = 3 THEN 1 END), 0),
            4
        ) AS win_rate_3star,

        -- Upgrade Intent / Reroll Popularity: % of total appearances successfully reaching 3-star
        ROUND(
            COUNT(CASE WHEN unit_tier = 3 THEN 1 END) * 100.0 
            / NULLIF(COUNT(DISTINCT participant_id), 0), 
            4
        ) AS upgrade_conversion_rate_pct

    FROM base_units
    GROUP BY 
        patch_version, 
        champion_id
    -- Sample size threshold to eliminate erratic high-roll noise
    HAVING COUNT(DISTINCT participant_id) >= 50
       AND COUNT(CASE WHEN unit_tier = 3 THEN 1 END) >= 10
),

-- 2. STATISTICAL DISTRIBUTION: Calculate Mean (μ) and Population StdDev (σ) partitioned by (patch_version, unit_rarity)
patch_rarity_distribution AS (
    SELECT
        patch_version,
        unit_rarity,
        
        -- Placement: μ and σ
        AVG(avg_placement_3star)                        AS mean_placement,
        STDDEV_POP(avg_placement_3star)                 AS std_placement,

        -- Top 4 Rate: μ and σ
        AVG(top4_rate_3star)                            AS mean_top4,
        STDDEV_POP(top4_rate_3star)                     AS std_top4,

        -- Win Rate: μ and σ
        AVG(win_rate_3star)                             AS mean_win,
        STDDEV_POP(win_rate_3star)                      AS std_win,

        -- Upgrade Intent / Popularity: Log-transformed to normalize skewed distributions across cost tiers
        AVG(LN(1 + upgrade_conversion_rate_pct))        AS mean_log_popularity,
        STDDEV_POP(LN(1 + upgrade_conversion_rate_pct)) AS std_log_popularity
    FROM champion_tier_aggregations
    GROUP BY 
        patch_version, 
        unit_rarity
),

-- 3. Standardized Gaussian Z-Scores & Weighted 40-30-20-10 Composite Scoring
calculate_z_scores AS (
    SELECT
        cta.patch_version,
        cta.champion_id,
        cta.champion_sk,
        cta.unit_rarity,
        cta.total_appearances,
        cta.count_2star,
        cta.count_3star,
        ROUND(cta.top4_rate_2star, 2)            AS top4_rate_2star,
        ROUND(cta.win_rate_2star, 2)             AS win_rate_2star,
        ROUND(cta.avg_placement_3star, 2)        AS avg_placement_3star,
        ROUND(cta.top4_rate_3star, 2)            AS top4_rate_3star,
        ROUND(cta.win_rate_3star, 2)             AS win_rate_3star,
        ROUND(cta.upgrade_conversion_rate_pct, 2) AS upgrade_conversion_rate_pct,

        -- Delta power upgrade (3-star vs 2-star ROI)
        ROUND(COALESCE(cta.top4_rate_3star, 0) - COALESCE(cta.top4_rate_2star, 0), 2) AS delta_top4_rate,
        ROUND(COALESCE(cta.win_rate_3star, 0) - COALESCE(cta.win_rate_2star, 0), 2)   AS delta_win_rate,

        -- Standardized Gaussian components
        -- Placement is inverted: smaller rank indicates higher performance
        ROUND((d.mean_placement - cta.avg_placement_3star) / NULLIF(d.std_placement, 0), 3)                           AS z_placement,
        ROUND((cta.top4_rate_3star - d.mean_top4) / NULLIF(d.std_top4, 0), 3)                                         AS z_top4,
        ROUND((cta.win_rate_3star - d.mean_win) / NULLIF(d.std_win, 0), 3)                                            AS z_win,
        ROUND((LN(1 + cta.upgrade_conversion_rate_pct) - d.mean_log_popularity) / NULLIF(d.std_log_popularity, 0), 3) AS z_popularity,

        -- STANDARDIZED COMPOSITE FORMULA: 40% Top 4 + 30% Inverted Placement + 20% Upgrade Intent + 10% Win Rate
        ROUND(
            (0.40 * ((cta.top4_rate_3star - d.mean_top4) / NULLIF(d.std_top4, 0))) +
            (0.30 * ((d.mean_placement - cta.avg_placement_3star) / NULLIF(d.std_placement, 0))) +
            (0.20 * ((LN(1 + cta.upgrade_conversion_rate_pct) - d.mean_log_popularity) / NULLIF(d.std_log_popularity, 0))) +
            (0.10 * ((cta.win_rate_3star - d.mean_win) / NULLIF(d.std_win, 0))),
            3
        ) AS composite_z_score

    FROM champion_tier_aggregations cta
    INNER JOIN patch_rarity_distribution d
        ON cta.patch_version = d.patch_version
       AND cta.unit_rarity = d.unit_rarity
),

-- 4. Meta role classification and patch ranking
ranked_reroll_champions AS (
    SELECT
        z.patch_version,
        
        -- Leaderboard rank within patch
        DENSE_RANK() OVER (
            PARTITION BY z.patch_version 
            ORDER BY z.composite_z_score DESC NULLS LAST, z.avg_placement_3star ASC
        ) AS reroll_tier_rank,

        -- Standard normal quantile tier labels
        CASE 
            WHEN z.composite_z_score >= 1.28 THEN 'S-Tier'
            WHEN z.composite_z_score >= 0.52 THEN 'A-Tier'
            WHEN z.composite_z_score >= -0.25 THEN 'B-Tier'
            ELSE 'C-Tier'
        END AS tier_label,

        -- Qualitative meta archetype recognition based on statistical performance
        CASE
            WHEN z.composite_z_score >= 0.52 AND z.upgrade_conversion_rate_pct >= 20.0 
                THEN 'Primary Reroll Carry'
            WHEN z.composite_z_score < -0.25 AND z.upgrade_conversion_rate_pct >= 20.0 
                THEN 'Bait / Low ROI Reroll'
            WHEN z.composite_z_score >= 0.52 AND z.upgrade_conversion_rate_pct < 15.0 
                THEN 'High Ceiling / Situational 3-Star'
            ELSE 'Trait Bot / 2-Star Placeholder'
        END AS reroll_archetype,

        z.champion_id,
        z.champion_sk,
        z.unit_rarity,

        -- Performance Scoring & Rates
        z.composite_z_score,
        z.upgrade_conversion_rate_pct,
        z.avg_placement_3star,
        z.top4_rate_3star,
        z.win_rate_3star,

        -- Detailed Z-Scores
        z.z_placement,
        z.z_top4,
        z.z_win,
        z.z_popularity,

        -- 3-Star vs 2-Star Delta ROI
        z.delta_top4_rate,
        z.delta_win_rate,

        -- Raw Context Counters
        z.count_3star,
        z.count_2star,
        z.top4_rate_2star,
        z.win_rate_2star,
        z.total_appearances
    FROM calculate_z_scores z
)

SELECT
    patch_version,
    reroll_tier_rank,
    tier_label,
    champion_id,
    champion_sk,
    unit_rarity,
    reroll_archetype,
    composite_z_score,
    upgrade_conversion_rate_pct,
    avg_placement_3star,
    top4_rate_3star,
    win_rate_3star,
    z_placement,
    z_top4,
    z_win,
    z_popularity,
    delta_top4_rate,
    delta_win_rate,
    count_3star,
    count_2star,
    top4_rate_2star,
    win_rate_2star,
    total_appearances
FROM ranked_reroll_champions
ORDER BY 
    patch_version DESC, 
    reroll_tier_rank ASC