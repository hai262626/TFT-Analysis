{{ config(
    materialized='table',
    schema='agg_matches'
) }}

WITH base_participant_artifacts AS (
    SELECT
        fpi.match_id,
        fpi.puuid,
        fpi.match_id || '_' || fpi.puuid AS participant_id,
        fpi.champion_id,
        fpi.placement,
        fpi.equipment_id,
        fpi.patch_version
    FROM {{ ref('fct_18_participant_items') }} fpi
    -- BUSINESS JOIN: Filter strictly for Artifact items via static dimension catalog
    INNER JOIN {{ ref('dim_18_equipments') }} de
        ON fpi.equipment_sk = de.equipment_sk
       AND de.item_category = 'Artifact'
    WHERE fpi.equipment_id IS NOT NULL 
      AND fpi.equipment_sk != '-1'
      AND fpi.patch_version != 'Unknown'
),

-- 1. Benchmark denominators: Total unique matches and participants with ANY artifact per champion
champion_artifact_benchmarks AS (
    SELECT
        patch_version,
        champion_id,
        COUNT(DISTINCT match_id)       AS total_artifact_matches,
        COUNT(DISTINCT participant_id) AS total_artifact_participants
    FROM base_participant_artifacts
    GROUP BY 
        patch_version, 
        champion_id
),

-- 2. Empirical aggregations per Champion x Artifact pair
champion_artifact_raw_aggregates AS (
    SELECT
        b.patch_version,
        b.champion_id,
        b.equipment_id,
        COUNT(DISTINCT b.participant_id)             AS unique_players_picked,
        COUNT(DISTINCT b.match_id)                   AS unique_matches_picked,
        ROUND(AVG(b.placement), 4)                   AS avg_placement,
        COUNT(CASE WHEN b.placement <= 4 THEN 1 END) AS top4_count,
        COUNT(CASE WHEN b.placement = 1 THEN 1 END)  AS win_count,

        -- Standardized Popularity Rates matching Marts Schema
        ROUND(
            COUNT(DISTINCT b.participant_id) * 100.0 / NULLIF(bm.total_artifact_participants, 0),
            4
        ) AS player_popularity_pct,
        ROUND(
            COUNT(DISTINCT b.match_id) * 100.0 / NULLIF(bm.total_artifact_matches, 0),
            4
        ) AS match_popularity_pct,

        ROUND(
            COUNT(CASE WHEN b.placement <= 4 THEN 1 END) * 100.0 / NULLIF(COUNT(DISTINCT b.participant_id), 0),
            4
        ) AS top4_rate_pct,
        ROUND(
            COUNT(CASE WHEN b.placement = 1 THEN 1 END) * 100.0 / NULLIF(COUNT(DISTINCT b.participant_id), 0),
            4
        ) AS win_rate_pct,

        bm.total_artifact_matches,
        bm.total_artifact_participants

    FROM base_participant_artifacts b
    INNER JOIN champion_artifact_benchmarks bm
        ON b.patch_version = bm.patch_version
       AND b.champion_id = bm.champion_id
    GROUP BY 
        b.patch_version, 
        b.champion_id, 
        b.equipment_id,
        bm.total_artifact_matches,
        bm.total_artifact_participants
    -- Sample size threshold to filter out noise from extreme edge cases
    HAVING COUNT(DISTINCT b.participant_id) >= 5
),

-- 3. STATISTICAL DISTRIBUTION: Calculate Mean (μ) and Population StdDev (σ) per (patch_version, champion_id)
champion_artifact_distribution AS (
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

        -- Popularity: Apply ln(1 + x) transformation to normalize skewed build distributions
        AVG(LN(1 + player_popularity_pct))        AS mean_log_popularity,
        STDDEV_POP(LN(1 + player_popularity_pct)) AS std_log_popularity
    FROM champion_artifact_raw_aggregates
    GROUP BY 
        patch_version, 
        champion_id
),

-- 4. Standardized Gaussian Z-Scores & Weighted 40-30-20-10 Composite Scoring
calculate_z_scores AS (
    SELECT
        r.patch_version,
        r.champion_id,
        r.equipment_id,
        ROUND(r.player_popularity_pct, 2) AS player_popularity_pct,
        ROUND(r.match_popularity_pct, 2)  AS match_popularity_pct,
        ROUND(r.avg_placement, 2)         AS avg_placement,
        ROUND(r.top4_rate_pct, 2)         AS top4_rate_pct,
        ROUND(r.win_rate_pct, 2)          AS win_rate_pct,
        r.unique_players_picked,
        r.unique_matches_picked,
        r.total_artifact_matches,
        r.total_artifact_participants,

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

    FROM champion_artifact_raw_aggregates r
    INNER JOIN champion_artifact_distribution d
        ON r.patch_version = d.patch_version
       AND r.champion_id = d.champion_id
),

-- 5. Rank artifacts per champion based on composite score with deterministic tie-breaking
ranked_artifacts AS (
    SELECT
        z.patch_version,
        z.champion_id,
        z.equipment_id,
        z.composite_z_score,
        z.unique_players_picked,
        DENSE_RANK() OVER (
            PARTITION BY z.patch_version, z.champion_id 
            ORDER BY 
                z.composite_z_score DESC NULLS LAST,
                z.unique_players_picked DESC,
                z.equipment_id ASC
        ) AS artifact_rank
    FROM calculate_z_scores z
),

-- 6. Pivot Top 3 artifacts into horizontal columns
top_3_artifacts_pivoted AS (
    SELECT
        patch_version,
        champion_id,
        MAX(CASE WHEN artifact_rank = 1 THEN equipment_id END) AS top_1_artifact,
        MAX(CASE WHEN artifact_rank = 2 THEN equipment_id END) AS top_2_artifact,
        MAX(CASE WHEN artifact_rank = 3 THEN equipment_id END) AS top_3_artifact
    FROM ranked_artifacts
    WHERE artifact_rank <= 3
    GROUP BY 
        patch_version, 
        champion_id
),

-- 7. Final consolidated projection
final_champion_artifacts AS (
    SELECT
        cb.patch_version,
        cb.champion_id,
        cb.total_artifact_participants AS total_games_with_artifacts,
        t3.top_1_artifact,
        t3.top_2_artifact,
        t3.top_3_artifact
    FROM champion_artifact_benchmarks cb
    LEFT JOIN top_3_artifacts_pivoted t3
        ON cb.patch_version = t3.patch_version
       AND cb.champion_id = t3.champion_id
)

SELECT
    patch_version,
    champion_id,
    total_games_with_artifacts,
    top_1_artifact,
    top_2_artifact,
    top_3_artifact
FROM final_champion_artifacts
ORDER BY 
    patch_version DESC, 
    total_games_with_artifacts DESC