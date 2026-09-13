{{ config(
    materialized='table',
    schema='agg_matches'
) }}

WITH base_participant_units AS (
    SELECT
        fpu.match_id,
        fpu.puuid,
        fpu.match_id || '_' || fpu.puuid AS participant_id,
        fpu.placement,
        fpu.champion_id,
        fpu.champion_sk,
        fpu.champion_version_sk,
        fpu.unit_rarity,
        fpu.patch_version
    FROM {{ ref('fct_18_participant_units') }} fpu
    /* 
      BUSINESS RULE: 
      Filter out unmapped patch versions to ensure strict statistical integrity.
    */
    WHERE fpu.patch_version != 'Unknown'
),

-- 1. Benchmark denominators: Total unique matches and participants per patch
patch_benchmarks AS (
    SELECT
        patch_version,
        COUNT(DISTINCT match_id)       AS total_matches,
        COUNT(DISTINCT participant_id) AS total_participants
    FROM base_participant_units
    GROUP BY patch_version
),

-- 2. Raw aggregations strictly grouped by champion entity per patch
champion_aggregations AS (
    SELECT
        patch_version,
        champion_id,
        MAX(champion_sk)                               AS champion_sk,
        MAX(champion_version_sk)                       AS champion_version_sk,
        MAX(unit_rarity)                               AS unit_rarity,
        COUNT(DISTINCT participant_id)                 AS unique_players_picked,
        COUNT(DISTINCT match_id)                       AS unique_matches_picked,
        ROUND(AVG(placement), 4)                       AS avg_placement,
        COUNT(CASE WHEN placement <= 4 THEN 1 END)     AS top4_count,
        COUNT(CASE WHEN placement = 1 THEN 1 END)      AS win_count
    FROM base_participant_units
    GROUP BY 
        patch_version,
        champion_id
    -- Baseline sample filter to eliminate statistical noise from low-volume edge occurrences
    HAVING COUNT(DISTINCT participant_id) >= 30
),

-- 3. Calculate empirical percentages and adoption rates
raw_rates AS (
    SELECT
        agg.patch_version,
        agg.champion_id,
        agg.champion_sk,
        agg.champion_version_sk,
        agg.unit_rarity,
        agg.unique_players_picked,
        agg.unique_matches_picked,
        ROUND(agg.avg_placement, 2) AS avg_placement,

        -- Standardized Popularity Rates matching Traits & Comps Mart Schema
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

    FROM champion_aggregations agg
    INNER JOIN patch_benchmarks bm
        ON agg.patch_version = bm.patch_version
),

-- 4. STATISTICAL DISTRIBUTION: Calculate Mean (μ) and Population StdDev (σ)
patch_champion_distribution AS (
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

        -- Popularity: Apply ln(1 + x) transformation to normalize right-skewed tails
        AVG(LN(1 + player_popularity_pct))        AS mean_log_popularity,
        STDDEV_POP(LN(1 + player_popularity_pct)) AS std_log_popularity
    FROM raw_rates
    GROUP BY patch_version
),

-- 5. Compute standard Z-Scores and weighted Composite Score (40% Top 4 + 30% Inverted Placement + 20% Popularity + 10% Win Rate)
calculate_z_scores AS (
    SELECT
        r.patch_version,
        r.champion_id,
        r.champion_sk,
        r.champion_version_sk,
        r.unit_rarity,
        ROUND(r.player_popularity_pct, 2) AS player_popularity_pct,
        ROUND(r.match_popularity_pct, 2)  AS match_popularity_pct,
        ROUND(r.avg_placement, 2)         AS avg_placement,
        ROUND(r.top4_rate_pct, 2)         AS top4_rate_pct,
        ROUND(r.win_rate_pct, 2)          AS win_rate_pct,
        r.unique_players_picked,
        r.unique_matches_picked,
        r.total_matches,
        r.total_participants,

        -- Standardized Z-Score components (Inverted placement: lower place yields higher positive score)
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
    INNER JOIN patch_champion_distribution d
        ON r.patch_version = d.patch_version
),

-- 6. Tier classification and historical delta calculation via window functions
calculate_patch_deltas AS (
    SELECT
        z.patch_version,
        
        -- Rank champions within each patch based on composite Gaussian score
        DENSE_RANK() OVER (
            PARTITION BY z.patch_version 
            ORDER BY z.composite_z_score DESC
        ) AS champion_rank,

        -- Tier classifications based on standard normal distribution quantiles
        CASE 
            WHEN z.composite_z_score >= 1.28 THEN 'S-Tier'
            WHEN z.composite_z_score >= 0.52 THEN 'A-Tier'
            WHEN z.composite_z_score >= -0.25 THEN 'B-Tier'
            ELSE 'C-Tier'
        END AS tier_label,

        z.champion_id,
        z.champion_sk,
        z.champion_version_sk,
        z.unit_rarity,
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
            PARTITION BY z.champion_id 
            ORDER BY z.patch_version ASC
        ) AS prev_composite_z_score,

        LAG(z.player_popularity_pct) OVER (
            PARTITION BY z.champion_id 
            ORDER BY z.patch_version ASC
        ) AS prev_player_popularity_pct,

        LAG(z.match_popularity_pct) OVER (
            PARTITION BY z.champion_id 
            ORDER BY z.patch_version ASC
        ) AS prev_match_popularity_pct,

        LAG(z.avg_placement) OVER (
            PARTITION BY z.champion_id 
            ORDER BY z.patch_version ASC
        ) AS prev_avg_placement,

        LAG(z.top4_rate_pct) OVER (
            PARTITION BY z.champion_id 
            ORDER BY z.patch_version ASC
        ) AS prev_top4_rate_pct,

        LAG(z.win_rate_pct) OVER (
            PARTITION BY z.champion_id 
            ORDER BY z.patch_version ASC
        ) AS prev_win_rate_pct,

        -- Patch-over-patch deltas
        ROUND(
            z.composite_z_score - LAG(z.composite_z_score) OVER (
                PARTITION BY z.champion_id 
                ORDER BY z.patch_version ASC
            ), 
            3
        ) AS delta_composite_z_score,

        ROUND(
            z.player_popularity_pct - LAG(z.player_popularity_pct) OVER (
                PARTITION BY z.champion_id 
                ORDER BY z.patch_version ASC
            ), 
            2
        ) AS delta_player_popularity_pct,

        ROUND(
            z.match_popularity_pct - LAG(z.match_popularity_pct) OVER (
                PARTITION BY z.champion_id 
                ORDER BY z.patch_version ASC
            ), 
            2
        ) AS delta_match_popularity_pct,

        ROUND(
            z.avg_placement - LAG(z.avg_placement) OVER (
                PARTITION BY z.champion_id 
                ORDER BY z.patch_version ASC
            ), 
            2
        ) AS delta_avg_placement,

        ROUND(
            z.top4_rate_pct - LAG(z.top4_rate_pct) OVER (
                PARTITION BY z.champion_id 
                ORDER BY z.patch_version ASC
            ), 
            2
        ) AS delta_top4_rate_pct,

        ROUND(
            z.win_rate_pct - LAG(z.win_rate_pct) OVER (
                PARTITION BY z.champion_id 
                ORDER BY z.patch_version ASC
            ), 
            2
        ) AS delta_win_rate_pct

    FROM calculate_z_scores z
)

SELECT
    patch_version,
    champion_rank,
    tier_label,
    champion_id,
    champion_sk,
    champion_version_sk,
    unit_rarity,
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
FROM calculate_patch_deltas
ORDER BY 
    patch_version DESC, 
    champion_rank ASC