{{ config(
    materialized='table',
    schema='agg_matches'
) }}

WITH player_base_matches AS (
    SELECT
        puuid,
        game_name,
        tagline,
        patch_version,
        placement,
        win,
        match_id
    FROM {{ ref('fct_18_participants') }}
    WHERE patch_version != 'Unknown'
      AND puuid IS NOT NULL
),

-- 1. Benchmark denominators per patch
patch_benchmarks AS (
    SELECT
        patch_version,
        COUNT(DISTINCT match_id) AS total_matches
    FROM player_base_matches
    GROUP BY patch_version
),

-- 2. Aggregate raw player performance metrics
player_raw_aggregates AS (
    SELECT
        pbm.patch_version,
        pbm.puuid,
        MAX(pbm.game_name)             AS game_name,
        MAX(pbm.tagline)               AS tagline,

        COUNT(DISTINCT pbm.match_id)   AS total_games_played,
        ROUND(AVG(pbm.placement), 4)   AS avg_placement,
        COUNT(CASE WHEN pbm.placement <= 4 THEN 1 END) AS top4_count,
        COUNT(CASE WHEN pbm.placement = 1 THEN 1 END)  AS win_count,

        ROUND(
            COUNT(DISTINCT pbm.match_id) * 100.0 / NULLIF(bm.total_matches, 0), 
            4
        ) AS match_participation_pct,

        ROUND(
            COUNT(CASE WHEN pbm.placement <= 4 THEN 1 END) * 100.0 / NULLIF(COUNT(DISTINCT pbm.match_id), 0), 
            4
        ) AS top4_rate_pct,
        ROUND(
            COUNT(CASE WHEN pbm.placement = 1 THEN 1 END) * 100.0 / NULLIF(COUNT(DISTINCT pbm.match_id), 0), 
            4
        ) AS win_rate_pct

    FROM player_base_matches pbm
    INNER JOIN patch_benchmarks bm
        ON pbm.patch_version = bm.patch_version
    GROUP BY 
        pbm.patch_version, 
        pbm.puuid,
        bm.total_matches
    HAVING COUNT(DISTINCT pbm.match_id) >= 10
),

-- 3. Statistical Distribution per patch
patch_player_distribution AS (
    SELECT
        patch_version,
        AVG(avg_placement)                          AS mean_placement,
        STDDEV_POP(avg_placement)                   AS std_placement,
        AVG(top4_rate_pct)                          AS mean_top4,
        STDDEV_POP(top4_rate_pct)                   AS std_top4,
        AVG(win_rate_pct)                           AS mean_win,
        STDDEV_POP(win_rate_pct)                    AS std_win,
        AVG(LN(1 + match_participation_pct))        AS mean_log_activity,
        STDDEV_POP(LN(1 + match_participation_pct)) AS std_log_activity
    FROM player_raw_aggregates
    GROUP BY patch_version
),

-- 4. Calculate Gaussian Z-Scores (40% Top 4 + 30% Inverted Placement + 20% Activity + 10% Win Rate)
player_scored AS (
    SELECT
        pra.patch_version,
        pra.puuid,
        pra.game_name,
        pra.tagline,
        pra.total_games_played,
        ROUND(pra.match_participation_pct, 2) AS match_participation_pct,
        ROUND(pra.avg_placement, 2)           AS avg_placement,
        ROUND(pra.top4_rate_pct, 2)           AS top4_rate_pct,
        ROUND(pra.win_rate_pct, 2)            AS win_rate_pct,

        -- Standardized components
        ROUND((pra.top4_rate_pct - d.mean_top4) / NULLIF(d.std_top4, 0), 3)                                     AS z_top4,
        ROUND((d.mean_placement - pra.avg_placement) / NULLIF(d.std_placement, 0), 3)                           AS z_placement,
        ROUND((pra.win_rate_pct - d.mean_win) / NULLIF(d.std_win, 0), 3)                                        AS z_win,
        ROUND((LN(1 + pra.match_participation_pct) - d.mean_log_activity) / NULLIF(d.std_log_activity, 0), 3) AS z_activity,

        ROUND(
            (0.40 * ((pra.top4_rate_pct - d.mean_top4) / NULLIF(d.std_top4, 0))) +
            (0.30 * ((d.mean_placement - pra.avg_placement) / NULLIF(d.std_placement, 0))) +
            (0.20 * ((LN(1 + pra.match_participation_pct) - d.mean_log_activity) / NULLIF(d.std_log_activity, 0))) +
            (0.10 * ((pra.win_rate_pct - d.mean_win) / NULLIF(d.std_win, 0))),
            3
        ) AS composite_z_score

    FROM player_raw_aggregates pra
    INNER JOIN patch_player_distribution d
        ON pra.patch_version = d.patch_version
),

-- 5. Final Leaderboard Ranking
ranked_players AS (
    SELECT
        ps.patch_version,
        DENSE_RANK() OVER (
            PARTITION BY ps.patch_version 
            ORDER BY ps.composite_z_score DESC NULLS LAST, ps.avg_placement ASC
        ) AS player_rank,

        CASE 
            WHEN ps.composite_z_score >= 1.28 THEN 'S-Tier'
            WHEN ps.composite_z_score >= 0.52 THEN 'A-Tier'
            WHEN ps.composite_z_score >= -0.25 THEN 'B-Tier'
            ELSE 'C-Tier'
        END AS tier_label,

        ps.puuid,
        ps.game_name,
        ps.tagline,
        ps.composite_z_score,
        ps.total_games_played,
        ps.avg_placement,
        ps.top4_rate_pct,
        ps.win_rate_pct,
        ps.match_participation_pct,
        ps.z_top4,
        ps.z_placement,
        ps.z_win,
        ps.z_activity
    FROM player_scored ps
)

SELECT
    patch_version,
    player_rank,
    tier_label,
    puuid,
    game_name,
    tagline,
    composite_z_score,
    total_games_played,
    avg_placement,
    top4_rate_pct,
    win_rate_pct,
    match_participation_pct,
    z_top4,
    z_placement,
    z_win,
    z_activity
FROM ranked_players
ORDER BY 
    patch_version DESC, 
    player_rank ASC