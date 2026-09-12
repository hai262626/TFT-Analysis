{{ config(
    materialized='table',
    schema='agg_matches'
) }}

WITH base_units AS (
    SELECT
        fpu.match_id,
        fpu.puuid,
        fpu.match_id || '_' || fpu.puuid AS participant_id,
        fpu.placement,
        fpu.champion_id,
        fpu.sorted_items,
        fpu.patch_version
    FROM {{ ref('fct_18_participant_units') }} fpu
    -- 1. Filter strictly for fully itemized carries with exactly 3 items and valid patch
    WHERE ARRAY_SIZE(fpu.sorted_items) = 3
      AND fpu.patch_version != 'Unknown'
),

-- 2. Extract item signatures directly from the pre-sorted array
extract_trio_signatures AS (
    SELECT
        patch_version,
        champion_id,
        participant_id,
        match_id,
        placement,
        
        -- The underlying array is pre-sorted, ensuring consistent signature hashes
        ARRAY_TO_STRING(sorted_items, ' + ') AS trio_signature,
        sorted_items[0]::STRING              AS item_1,
        sorted_items[1]::STRING              AS item_2,
        sorted_items[2]::STRING              AS item_3
    FROM base_units
),

-- 3. Benchmark denominators: Total unique 3-item games and matches per champion within the patch
champion_3item_benchmarks AS (
    SELECT
        patch_version,
        champion_id,
        COUNT(DISTINCT match_id)       AS total_3item_matches,
        COUNT(DISTINCT participant_id) AS total_3item_participants
    FROM extract_trio_signatures
    GROUP BY 
        patch_version, 
        champion_id
),

-- 4. Empirical performance aggregations per 3-item combination
trio_raw_aggregates AS (
    SELECT
        t.patch_version,
        t.champion_id,
        t.trio_signature,
        t.item_1,
        t.item_2,
        t.item_3,

        COUNT(DISTINCT t.participant_id)             AS unique_players_picked,
        COUNT(DISTINCT t.match_id)                   AS unique_matches_picked,
        ROUND(AVG(t.placement), 4)                   AS avg_placement,
        COUNT(CASE WHEN t.placement <= 4 THEN 1 END) AS top4_count,
        COUNT(CASE WHEN t.placement = 1 THEN 1 END)  AS win_count,

        -- Standardized Popularity Rates matching Marts Schema
        ROUND(
            COUNT(DISTINCT t.participant_id) * 100.0 / NULLIF(bm.total_3item_participants, 0),
            4
        ) AS player_popularity_pct,
        ROUND(
            COUNT(DISTINCT t.match_id) * 100.0 / NULLIF(bm.total_3item_matches, 0),
            4
        ) AS match_popularity_pct,

        ROUND(
            COUNT(CASE WHEN t.placement <= 4 THEN 1 END) * 100.0 / NULLIF(COUNT(DISTINCT t.participant_id), 0),
            4
        ) AS top4_rate_pct,
        ROUND(
            COUNT(CASE WHEN t.placement = 1 THEN 1 END) * 100.0 / NULLIF(COUNT(DISTINCT t.participant_id), 0),
            4
        ) AS win_rate_pct,

        bm.total_3item_matches,
        bm.total_3item_participants

    FROM extract_trio_signatures t
    INNER JOIN champion_3item_benchmarks bm
        ON t.patch_version = bm.patch_version
       AND t.champion_id = bm.champion_id
    GROUP BY 
        t.patch_version,
        t.champion_id,
        t.trio_signature,
        t.item_1,
        t.item_2,
        t.item_3,
        bm.total_3item_matches,
        bm.total_3item_participants
    -- Sample size threshold to filter out noise from unconventional itemizations
    HAVING COUNT(DISTINCT t.participant_id) >= 10
),

-- 5. STATISTICAL DISTRIBUTION: Calculate Mean (μ) and Population StdDev (σ) per (patch_version, champion_id)
champion_trio_distribution AS (
    SELECT
        patch_version,
        champion_id,
        
        -- Placement: μ and σ
        AVG(avg_placement)                        AS mean_placement,
        STDDEV_POP(avg_placement)                 AS std_placement,

        -- Top 4 Rate: μ and σ
        AVG(top4_rate_pct)                        AS mean_top4,
        STDDEV_POP(top4_rate_pct)                 AS std_top4,

        -- Win Rate: μ and σ
        AVG(win_rate_pct)                         AS mean_win,
        STDDEV_POP(win_rate_pct)                  AS std_win,

        -- Popularity: Apply ln(1 + x) transformation to normalize right-skewed build distributions
        AVG(LN(1 + player_popularity_pct))        AS mean_log_popularity,
        STDDEV_POP(LN(1 + player_popularity_pct)) AS std_log_popularity
    FROM trio_raw_aggregates
    GROUP BY 
        patch_version, 
        champion_id
),

-- 6. Standardized Gaussian Z-Scores & Weighted 40-30-20-10 Composite Scoring
calculate_z_scores AS (
    SELECT
        r.patch_version,
        r.champion_id,
        r.trio_signature,
        r.item_1,
        r.item_2,
        r.item_3,
        ROUND(r.player_popularity_pct, 2) AS player_popularity_pct,
        ROUND(r.match_popularity_pct, 2)  AS match_popularity_pct,
        ROUND(r.avg_placement, 2)         AS avg_placement,
        ROUND(r.top4_rate_pct, 2)         AS top4_rate_pct,
        ROUND(r.win_rate_pct, 2)          AS win_rate_pct,
        r.unique_players_picked,
        r.unique_matches_picked,
        r.total_3item_matches,
        r.total_3item_participants,

        -- Standardized Z-Score components
        -- Inverted placement: smaller value indicates higher ranking
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

    FROM trio_raw_aggregates r
    INNER JOIN champion_trio_distribution d
        ON r.patch_version = d.patch_version
       AND r.champion_id = d.champion_id
),

-- 7. Rank assignments and tier categorization per champion
ranked_trios AS (
    SELECT
        z.patch_version,
        z.champion_id,
        
        -- Rank item builds for each champion based on composite score
        DENSE_RANK() OVER (
            PARTITION BY z.patch_version, z.champion_id 
            ORDER BY z.composite_z_score DESC
        ) AS trio_tier_rank,

        -- Standard normal quantile tier labels
        CASE 
            WHEN z.composite_z_score >= 1.28 THEN 'S-Tier'
            WHEN z.composite_z_score >= 0.52 THEN 'A-Tier'
            WHEN z.composite_z_score >= -0.25 THEN 'B-Tier'
            ELSE 'C-Tier'
        END AS tier_label,

        z.trio_signature,
        z.item_1,
        z.item_2,
        z.item_3,

        -- Meta Scoring & Rates
        z.composite_z_score,
        z.player_popularity_pct,
        z.match_popularity_pct,
        z.avg_placement,
        z.top4_rate_pct,
        z.win_rate_pct,

        -- Detailed Z-Scores
        z.z_placement,
        z.z_top4,
        z.z_win,
        z.z_popularity,

        -- Context Counters
        z.unique_players_picked,
        z.unique_matches_picked,
        z.total_3item_matches,
        z.total_3item_participants
    FROM calculate_z_scores z
)

SELECT
    patch_version,
    champion_id,
    trio_tier_rank,
    tier_label,
    trio_signature,
    item_1,
    item_2,
    item_3,
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
    total_3item_matches,
    total_3item_participants
FROM ranked_trios
ORDER BY 
    patch_version DESC, 
    champion_id ASC, 
    trio_tier_rank ASC,
    composite_z_score DESC NULLS LAST