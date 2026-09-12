{{ config(
    materialized='table',
    schema='agg_matches'
) }}

WITH base_participant_traits AS (
    SELECT
        fpt.match_id,
        fpt.puuid,
        fpt.match_id || '_' || fpt.puuid AS participant_id,
        fpt.game_datetime,
        fpt.placement,
        fpt.trait_id,
        fpt.num_units,
        fpt.style,
        fpt.tier_current,
        fpt.tier_total
    FROM {{ ref('fct_18_participant_traits') }} fpt
    /* 
      BUSINESS RULE: 
      Filter strictly for active trait tiers that are actually activated (style > 0 and tier_current > 0).
    */
    WHERE fpt.style > 0 
      AND fpt.tier_current > 0
),

-- 1. Map each record to the active TFT patch release window
add_patch_version AS (
    SELECT
        b.*,
        COALESCE(p.patch_version, 'Unknown') AS patch_version
    FROM base_participant_traits b
    LEFT JOIN {{ ref('tft_patch_version') }} p 
        ON b.game_datetime >= p.patch_release_utc
       AND b.game_datetime < p.patch_end_utc
    WHERE COALESCE(p.patch_version, 'Unknown') != 'Unknown'
),

-- 2. Benchmark denominators: Total unique matches and participants per patch
patch_benchmarks AS (
    SELECT
        patch_version,
        COUNT(DISTINCT match_id)       AS total_matches,
        COUNT(DISTINCT participant_id) AS total_participants
    FROM add_patch_version
    GROUP BY patch_version
),

-- 3. Raw aggregations by trait tier activation milestone
trait_tier_aggregations AS (
    SELECT
        patch_version,
        trait_id,
        tier_current,
        tier_total,
        style,
        MIN(num_units)                                 AS min_units_activated,
        COUNT(DISTINCT participant_id)                 AS unique_players_picked,
        COUNT(DISTINCT match_id)                       AS unique_matches_picked,
        ROUND(AVG(placement), 4)                       AS avg_placement,
        COUNT(CASE WHEN placement <= 4 THEN 1 END)     AS top4_count,
        COUNT(CASE WHEN placement = 1 THEN 1 END)      AS win_count
    FROM add_patch_version
    GROUP BY 
        patch_version,
        trait_id,
        tier_current,
        tier_total,
        style
    HAVING COUNT(DISTINCT participant_id) >= 30
),

-- 4. Calculate empirical percentages and adoption rates
raw_rates AS (
    SELECT
        agg.patch_version,
        agg.trait_id,
        agg.tier_current,
        agg.tier_total,
        agg.style,
        agg.min_units_activated,
        agg.unique_players_picked,
        agg.unique_matches_picked,
        ROUND(agg.avg_placement, 2) AS avg_placement,

        -- Standardized Popularity Rates matching Items & Comps Mart Schema
        ROUND(
            agg.unique_players_picked * 100.0 / NULLIF(bm.total_participants, 0), 
            4
        ) AS player_popularity_pct,
        ROUND(
            agg.unique_matches_picked * 100.0 / NULLIF(bm.total_matches, 0), 
            4
        ) AS match_popularity_pct,

        -- Performance rates
        ROUND(
            agg.top4_count * 100.0 / NULLIF(agg.unique_players_picked, 0), 
            4
        ) AS top4_rate_pct,

        ROUND(
            agg.win_count * 100.0 / NULLIF(agg.unique_players_picked, 0), 
            4
        ) AS win_rate_pct,

        bm.total_matches,
        bm.total_participants

    FROM trait_tier_aggregations agg
    INNER JOIN patch_benchmarks bm
        ON agg.patch_version = bm.patch_version
),

-- 5. STATISTICAL DISTRIBUTION: Calculate Mean (μ) and Population StdDev (σ)
patch_trait_distribution AS (
    SELECT
        patch_version,
        
        -- Placement: μ and σ
        AVG(avg_placement)                        AS mean_placement,
        STDDEV_POP(avg_placement)                 AS std_placement,

        -- Top 4 Rate: μ and σ
        AVG(top4_rate_pct)                        AS mean_top4,
        STDDEV_POP(top4_rate_pct)                 AS std_top4,

        -- Win Rate: μ and σ
        AVG(win_rate_pct)                         AS mean_win,
        STDDEV_POP(win_rate_pct)                  AS std_win,

        -- Popularity: Apply ln(1 + x) transformation to pull right-skewed tails into Gaussian normality
        AVG(LN(1 + player_popularity_pct))        AS mean_log_popularity,
        STDDEV_POP(LN(1 + player_popularity_pct)) AS std_log_popularity
    FROM raw_rates
    GROUP BY patch_version
),

-- 6. Compute standard Z-Scores and weighted Composite Score (40% Top 4 + 30% Inverted Placement + 20% Popularity + 10% Win Rate)
calculate_z_scores AS (
    SELECT
        r.patch_version,
        r.trait_id,
        r.tier_current,
        r.tier_total,
        r.style,
        r.min_units_activated,
        ROUND(r.player_popularity_pct, 2) AS player_popularity_pct,
        ROUND(r.match_popularity_pct, 2)  AS match_popularity_pct,
        ROUND(r.avg_placement, 2)         AS avg_placement,
        ROUND(r.top4_rate_pct, 2)         AS top4_rate_pct,
        ROUND(r.win_rate_pct, 2)          AS win_rate_pct,
        r.unique_players_picked,
        r.unique_matches_picked,
        r.total_matches,
        r.total_participants,

        -- Standardized Z-Score components
        -- Placement is inverted: smaller rank means better performance
        ROUND((d.mean_placement - r.avg_placement) / NULLIF(d.std_placement, 0), 3)                           AS z_placement,
        ROUND((r.top4_rate_pct - d.mean_top4) / NULLIF(d.std_top4, 0), 3)                                     AS z_top4,
        ROUND((r.win_rate_pct - d.mean_win) / NULLIF(d.std_win, 0), 3)                                        AS z_win,
        ROUND((LN(1 + r.player_popularity_pct) - d.mean_log_popularity) / NULLIF(d.std_log_popularity, 0), 3) AS z_popularity,

        -- STANDARDIZED COMPOSITE FORMULA: 40% Top 4 + 30% Inverted Placement + 20% Popularity + 10% Win Rate
        ROUND(
            (0.40 * ((r.top4_rate_pct - d.mean_top4) / NULLIF(d.std_top4, 0))) +
            (0.30 * ((d.mean_placement - r.avg_placement) / NULLIF(d.std_placement, 0))) +
            (0.20 * ((LN(1 + r.player_popularity_pct) - d.mean_log_popularity) / NULLIF(d.std_log_popularity, 0))) +
            (0.10 * ((r.win_rate_pct - d.mean_win) / NULLIF(d.std_win, 0))),
            3
        ) AS composite_z_score

    FROM raw_rates r
    INNER JOIN patch_trait_distribution d
        ON r.patch_version = d.patch_version
),

-- 7. Tier classification and historical delta calculation via window functions
calculate_patch_deltas AS (
    SELECT
        z.patch_version,
        
        -- Rank trait tiers within each patch based on composite Gaussian score
        DENSE_RANK() OVER (
            PARTITION BY z.patch_version 
            ORDER BY z.composite_z_score DESC
        ) AS trait_tier_rank,

        -- Tier classifications based on standard normal distribution quantiles
        CASE 
            WHEN z.composite_z_score >= 1.28 THEN 'S-Tier'
            WHEN z.composite_z_score >= 0.52 THEN 'A-Tier'
            WHEN z.composite_z_score >= -0.25 THEN 'B-Tier'
            ELSE 'C-Tier'
        END AS tier_label,

        z.trait_id,
        z.tier_current,
        z.tier_total,
        z.style,
        z.min_units_activated,
        z.composite_z_score,
        z.player_popularity_pct,
        z.match_popularity_pct,
        z.avg_placement,
        z.top4_rate_pct,
        z.win_rate_pct,
        z.z_placement,
        z.z_top4,
        z.z_win,
        z.z_popularity,
        z.unique_players_picked,
        z.unique_matches_picked,
        z.total_matches,
        z.total_participants,

        -- Previous patch benchmarks
        LAG(z.composite_z_score) OVER (
            PARTITION BY z.trait_id, z.tier_current 
            ORDER BY z.patch_version ASC
        ) AS prev_composite_z_score,

        LAG(z.player_popularity_pct) OVER (
            PARTITION BY z.trait_id, z.tier_current 
            ORDER BY z.patch_version ASC
        ) AS prev_player_popularity_pct,

        LAG(z.match_popularity_pct) OVER (
            PARTITION BY z.trait_id, z.tier_current 
            ORDER BY z.patch_version ASC
        ) AS prev_match_popularity_pct,

        LAG(z.avg_placement) OVER (
            PARTITION BY z.trait_id, z.tier_current 
            ORDER BY z.patch_version ASC
        ) AS prev_avg_placement,

        LAG(z.top4_rate_pct) OVER (
            PARTITION BY z.trait_id, z.tier_current 
            ORDER BY z.patch_version ASC
        ) AS prev_top4_rate_pct,

        LAG(z.win_rate_pct) OVER (
            PARTITION BY z.trait_id, z.tier_current 
            ORDER BY z.patch_version ASC
        ) AS prev_win_rate_pct,

        -- Patch-over-patch deltas
        ROUND(
            z.composite_z_score - LAG(z.composite_z_score) OVER (
                PARTITION BY z.trait_id, z.tier_current 
                ORDER BY z.patch_version ASC
            ), 
            3
        ) AS delta_composite_z_score,

        ROUND(
            z.player_popularity_pct - LAG(z.player_popularity_pct) OVER (
                PARTITION BY z.trait_id, z.tier_current 
                ORDER BY z.patch_version ASC
            ), 
            2
        ) AS delta_player_popularity_pct,

        ROUND(
            z.match_popularity_pct - LAG(z.match_popularity_pct) OVER (
                PARTITION BY z.trait_id, z.tier_current 
                ORDER BY z.patch_version ASC
            ), 
            2
        ) AS delta_match_popularity_pct,

        ROUND(
            z.avg_placement - LAG(z.avg_placement) OVER (
                PARTITION BY z.trait_id, z.tier_current 
                ORDER BY z.patch_version ASC
            ), 
            2
        ) AS delta_avg_placement,

        ROUND(
            z.top4_rate_pct - LAG(z.top4_rate_pct) OVER (
                PARTITION BY z.trait_id, z.tier_current 
                ORDER BY z.patch_version ASC
            ), 
            2
        ) AS delta_top4_rate_pct,

        ROUND(
            z.win_rate_pct - LAG(z.win_rate_pct) OVER (
                PARTITION BY z.trait_id, z.tier_current 
                ORDER BY z.patch_version ASC
            ), 
            2
        ) AS delta_win_rate_pct

    FROM calculate_z_scores z
),

-- 8. Enrich aggregate records with dimensional metadata and descriptive tier attributes
enrich_with_trait_tier_dimension AS (
    SELECT
        cpd.patch_version,
        cpd.trait_tier_rank,
        cpd.tier_label,
        cpd.trait_id,
        COALESCE(dim.tier_id, 'Unknown')                  AS tier_id,
        COALESCE(dim.tier_version_sk, '-1')               AS tier_version_sk,
        COALESCE(dim.tier_sk, '-1')                       AS tier_sk,
        cpd.tier_current,
        cpd.tier_total,
        COALESCE(dim.min_units, cpd.min_units_activated) AS defined_min_units,
        COALESCE(dim.max_units, 0)                       AS defined_max_units,
        COALESCE(dim.style, cpd.style)                   AS defined_style,
        dim.tier_variables,

        -- Meta Scoring & Rates (Standardized naming matching Items & Comps Mart)
        cpd.composite_z_score,
        cpd.player_popularity_pct,
        cpd.match_popularity_pct,
        cpd.avg_placement,
        cpd.top4_rate_pct,
        cpd.win_rate_pct,

        -- Detailed Z-Scores
        cpd.z_placement,
        cpd.z_top4,
        cpd.z_win,
        cpd.z_popularity,

        -- Historical Benchmarks & Deltas
        cpd.prev_composite_z_score,
        cpd.delta_composite_z_score,
        cpd.prev_player_popularity_pct,
        cpd.delta_player_popularity_pct,
        cpd.prev_match_popularity_pct,
        cpd.delta_match_popularity_pct,
        cpd.prev_avg_placement,
        cpd.delta_avg_placement,
        cpd.prev_top4_rate_pct,
        cpd.delta_top4_rate_pct,
        cpd.prev_win_rate_pct,
        cpd.delta_win_rate_pct,

        -- Context Counters
        cpd.unique_players_picked,
        cpd.unique_matches_picked,
        cpd.total_matches,
        cpd.total_participants
    FROM calculate_patch_deltas cpd
    LEFT JOIN {{ ref('dim_18_traits_tiers') }} dim
        ON cpd.trait_id = dim.trait_id
       AND cpd.tier_current = dim.tier_level
       AND cpd.patch_version = dim.patch_version
)

SELECT
    patch_version,
    trait_tier_rank,
    tier_label,
    trait_id,
    tier_id,
    tier_version_sk,
    tier_sk,
    tier_current,
    tier_total,
    defined_min_units,
    defined_max_units,
    defined_style,
    tier_variables,
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
    prev_composite_z_score,
    delta_composite_z_score,
    prev_player_popularity_pct,
    delta_player_popularity_pct,
    prev_match_popularity_pct,
    delta_match_popularity_pct,
    prev_avg_placement,
    delta_avg_placement,
    prev_top4_rate_pct,
    delta_top4_rate_pct,
    prev_win_rate_pct,
    delta_win_rate_pct,
    unique_players_picked,
    unique_matches_picked,
    total_matches,
    total_participants
FROM enrich_with_trait_tier_dimension
ORDER BY 
    patch_version DESC, 
    trait_tier_rank ASC