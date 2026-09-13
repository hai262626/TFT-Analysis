{{ config(
    materialized='table',
    schema='agg_matches'
) }}

WITH base_participant_items AS (
    SELECT
        match_id,
        puuid,
        match_id || '_' || puuid AS participant_id,
        champion_id,
        placement,
        equipment_sk,
        equipment_id,
        patch_version
    FROM {{ ref('fct_18_participant_items') }}
    WHERE equipment_id IS NOT NULL 
      AND equipment_sk != '-1'
      AND patch_version != 'Unknown'
),

-- 1. Compute lobby benchmarks per patch
patch_benchmarks AS (
    SELECT
        patch_version,
        COUNT(DISTINCT match_id)       AS total_matches,
        COUNT(DISTINCT participant_id) AS total_participants
    FROM base_participant_items
    GROUP BY patch_version
),

-- 2. Deduplicate at participant level to eliminate bias on AVG placement & rates
unique_player_equipment_outcomes AS (
    SELECT DISTINCT
        patch_version,
        equipment_sk,
        equipment_id,
        participant_id,
        match_id,
        placement
    FROM base_participant_items
),

-- 3. Calculate equipment usage per champion to determine Top 5 users
champion_equipment_popularity AS (
    SELECT
        patch_version,
        equipment_id,
        champion_id,
        COUNT(DISTINCT participant_id) AS champ_pick_count,
        DENSE_RANK() OVER (
            PARTITION BY patch_version, equipment_id 
            ORDER BY COUNT(DISTINCT participant_id) DESC, champion_id ASC
        ) AS champ_rank
    FROM base_participant_items
    GROUP BY 
        patch_version, 
        equipment_id, 
        champion_id
),

-- 4. Pivot Top 5 champions into distinct columns
top_5_champions_pivoted AS (
    SELECT
        patch_version,
        equipment_id,
        MAX(CASE WHEN champ_rank = 1 THEN champion_id END) AS top_1_champ,
        MAX(CASE WHEN champ_rank = 2 THEN champion_id END) AS top_2_champ,
        MAX(CASE WHEN champ_rank = 3 THEN champion_id END) AS top_3_champ,
        MAX(CASE WHEN champ_rank = 4 THEN champion_id END) AS top_4_champ,
        MAX(CASE WHEN champ_rank = 5 THEN champion_id END) AS top_5_champ
    FROM champion_equipment_popularity
    WHERE champ_rank <= 5
    GROUP BY 
        patch_version, 
        equipment_id
),

-- 5. Aggregate overall item metrics safely without duplicate bias
item_aggregations AS (
    SELECT
        u.patch_version,
        u.equipment_sk,
        u.equipment_id,

        -- Adoption
        COUNT(DISTINCT u.participant_id) AS unique_players_picked,
        COUNT(DISTINCT u.match_id)       AS unique_matches_picked,

        -- Unbiased Performance Metrics
        ROUND(AVG(u.placement), 4)       AS avg_placement,
        COUNT(CASE WHEN u.placement <= 4 THEN 1 END) AS top4_count,
        COUNT(CASE WHEN u.placement = 1 THEN 1 END)  AS win_count,

        -- Total Volume (includes duplicated items on same player)
        COUNT(b.equipment_id)            AS total_items_crafted

    FROM unique_player_equipment_outcomes u
    LEFT JOIN base_participant_items b
        ON u.patch_version = b.patch_version
       AND u.participant_id = b.participant_id
       AND u.equipment_id = b.equipment_id
    GROUP BY 
        u.patch_version,
        u.equipment_sk,
        u.equipment_id
    -- Minimum sample size threshold to eliminate statistical noise
    HAVING COUNT(DISTINCT u.participant_id) >= 30
),

-- 6. Enrich with catalog data, top champs, and compute rates
calculate_metrics_and_enrich AS (
    SELECT
        agg.patch_version,
        agg.equipment_sk,
        agg.equipment_id,
        de.equipment_name,

        -- Top 5 Champions
        c5.top_1_champ,
        c5.top_2_champ,
        c5.top_3_champ,
        c5.top_4_champ,
        c5.top_5_champ,

        -- Adoption & Multiplicity
        ROUND(
            agg.unique_players_picked * 100.0 / NULLIF(bm.total_participants, 0), 
            4
        ) AS player_popularity_pct,
        ROUND(
            agg.unique_matches_picked * 100.0 / NULLIF(bm.total_matches, 0), 
            4
        ) AS match_popularity_pct,
        ROUND(
            agg.total_items_crafted * 1.0 / NULLIF(agg.unique_players_picked, 0), 
            2
        ) AS duplicate_craft_ratio,

        -- Rates
        agg.avg_placement,
        ROUND(
            agg.top4_count * 100.0 / NULLIF(agg.unique_players_picked, 0), 
            4
        ) AS top4_rate_pct,
        ROUND(
            agg.win_count * 100.0 / NULLIF(agg.unique_players_picked, 0), 
            4
        ) AS win_rate_pct,

        -- Volume counters
        agg.unique_players_picked,
        agg.total_items_crafted,
        bm.total_matches,
        bm.total_participants

    FROM item_aggregations agg
    INNER JOIN patch_benchmarks bm
        ON agg.patch_version = bm.patch_version
    LEFT JOIN top_5_champions_pivoted c5
        ON agg.patch_version = c5.patch_version
       AND agg.equipment_id = c5.equipment_id
    LEFT JOIN {{ ref('dim_18_equipments') }} de
        ON agg.equipment_sk = de.equipment_sk
),

-- 7. STATISTICAL DISTRIBUTION: Calculate Mean (μ) and Population StdDev (σ) across all items per patch
patch_item_distribution AS (
    SELECT
        patch_version,
        
        -- Placement: μ and σ
        AVG(avg_placement)              AS mean_placement,
        STDDEV_POP(avg_placement)       AS std_placement,

        -- Top 4 Rate: μ and σ
        AVG(top4_rate_pct)              AS mean_top4,
        STDDEV_POP(top4_rate_pct)       AS std_top4,

        -- Win Rate: μ and σ
        AVG(win_rate_pct)               AS mean_win,
        STDDEV_POP(win_rate_pct)        AS std_win,

        -- Popularity: Apply ln(1 + x) transformation to normalize right-skewed distribution
        AVG(LN(1 + player_popularity_pct))        AS mean_log_popularity,
        STDDEV_POP(LN(1 + player_popularity_pct)) AS std_log_popularity
    FROM calculate_metrics_and_enrich
    GROUP BY patch_version
),

-- 8. Compute standardized Z-Scores and weighted Composite Score
calculate_z_scores AS (
    SELECT
        c.patch_version,
        c.equipment_sk,
        c.equipment_id,
        c.equipment_name,
        c.top_1_champ,
        c.top_2_champ,
        c.top_3_champ,
        c.top_4_champ,
        c.top_5_champ,
        ROUND(c.player_popularity_pct, 2) AS player_popularity_pct,
        ROUND(c.match_popularity_pct, 2)  AS match_popularity_pct,
        c.duplicate_craft_ratio,
        ROUND(c.avg_placement, 2)         AS avg_placement,
        ROUND(c.top4_rate_pct, 2)         AS top4_rate_pct,
        ROUND(c.win_rate_pct, 2)          AS win_rate_pct,
        c.unique_players_picked,
        c.total_items_crafted,
        c.total_matches,
        c.total_participants,

        -- Standardized Z-Score components
        -- Placement is inverted: smaller rank means better performance
        ROUND((d.mean_placement - c.avg_placement) / NULLIF(d.std_placement, 0), 3)                   AS z_placement,
        ROUND((c.top4_rate_pct - d.mean_top4) / NULLIF(d.std_top4, 0), 3)                             AS z_top4,
        ROUND((c.win_rate_pct - d.mean_win) / NULLIF(d.std_win, 0), 3)                                AS z_win,
        ROUND((LN(1 + c.player_popularity_pct) - d.mean_log_popularity) / NULLIF(d.std_log_popularity, 0), 3) AS z_popularity,

        -- COMPOSITE Z-SCORE FORMULA: 40% Top 4 + 30% Inverted Placement + 20% Popularity + 10% Win Rate
        ROUND(
            (0.40 * ((c.top4_rate_pct - d.mean_top4) / NULLIF(d.std_top4, 0))) +
            (0.30 * ((d.mean_placement - c.avg_placement) / NULLIF(d.std_placement, 0))) +
            (0.20 * ((LN(1 + c.player_popularity_pct) - d.mean_log_popularity) / NULLIF(d.std_log_popularity, 0))) +
            (0.10 * ((c.win_rate_pct - d.mean_win) / NULLIF(d.std_win, 0))),
            3
        ) AS composite_z_score

    FROM calculate_metrics_and_enrich c
    INNER JOIN patch_item_distribution d
        ON c.patch_version = d.patch_version
),

-- 9. Tier classification and historical delta calculation via window functions
calculate_patch_deltas AS (
    SELECT
        z.patch_version,
        z.equipment_id,
        -- Rank items within each patch based on composite Gaussian score
        DENSE_RANK() OVER (
            PARTITION BY z.patch_version 
            ORDER BY z.composite_z_score DESC
        ) AS item_tier_rank,

        -- Tier classifications based on standard normal distribution quantiles
        CASE 
            WHEN z.composite_z_score >= 1.28 THEN 'S-Tier'   -- Top ~10%
            WHEN z.composite_z_score >= 0.52 THEN 'A-Tier'   -- Top ~30%
            WHEN z.composite_z_score >= -0.25 THEN 'B-Tier'  -- Average range
            ELSE 'C-Tier'
        END AS tier_label,

        z.equipment_sk,
        z.equipment_name,
        z.top_1_champ,
        z.top_2_champ,
        z.top_3_champ,
        z.top_4_champ,
        z.top_5_champ,
        z.composite_z_score,
        z.player_popularity_pct,
        z.match_popularity_pct,
        z.duplicate_craft_ratio,
        z.avg_placement,
        z.top4_rate_pct,
        z.win_rate_pct,
        z.z_placement,
        z.z_top4,
        z.z_win,
        z.z_popularity,
        z.unique_players_picked,
        z.total_items_crafted,
        z.total_matches,
        z.total_participants,

        -- Previous patch benchmarks
        LAG(z.composite_z_score) OVER (
            PARTITION BY z.equipment_id 
            ORDER BY z.patch_version ASC
        ) AS prev_composite_z_score,

        LAG(z.player_popularity_pct) OVER (
            PARTITION BY z.equipment_id 
            ORDER BY z.patch_version ASC
        ) AS prev_player_popularity_pct,

        LAG(z.avg_placement) OVER (
            PARTITION BY z.equipment_id 
            ORDER BY z.patch_version ASC
        ) AS prev_avg_placement,

        LAG(z.top4_rate_pct) OVER (
            PARTITION BY z.equipment_id 
            ORDER BY z.patch_version ASC
        ) AS prev_top4_rate_pct,

        LAG(z.win_rate_pct) OVER (
            PARTITION BY z.equipment_id 
            ORDER BY z.patch_version ASC
        ) AS prev_win_rate_pct,

        -- Patch-over-patch deltas
        ROUND(
            z.composite_z_score - LAG(z.composite_z_score) OVER (
                PARTITION BY z.equipment_id 
                ORDER BY z.patch_version ASC
            ), 
            3
        ) AS delta_composite_z_score,

        ROUND(
            z.player_popularity_pct - LAG(z.player_popularity_pct) OVER (
                PARTITION BY z.equipment_id 
                ORDER BY z.patch_version ASC
            ), 
            2
        ) AS delta_player_popularity_pct,

        ROUND(
            z.avg_placement - LAG(z.avg_placement) OVER (
                PARTITION BY z.equipment_id 
                ORDER BY z.patch_version ASC
            ), 
            2
        ) AS delta_avg_placement,

        ROUND(
            z.top4_rate_pct - LAG(z.top4_rate_pct) OVER (
                PARTITION BY z.equipment_id 
                ORDER BY z.patch_version ASC
            ), 
            2
        ) AS delta_top4_rate_pct,

        ROUND(
            z.win_rate_pct - LAG(z.win_rate_pct) OVER (
                PARTITION BY z.equipment_id 
                ORDER BY z.patch_version ASC
            ), 
            2
        ) AS delta_win_rate_pct

    FROM calculate_z_scores z
)

-- Final SELECT strictly projects from calculate_patch_deltas without redundant CTEs
SELECT
    patch_version,
    item_tier_rank,
    tier_label,
    equipment_sk,
    equipment_id,
    equipment_name,

    -- Top 5 Users
    top_1_champ,
    top_2_champ,
    top_3_champ,
    top_4_champ,
    top_5_champ,

    -- Meta Scoring
    composite_z_score,
    player_popularity_pct,
    match_popularity_pct,
    duplicate_craft_ratio,
    avg_placement,
    top4_rate_pct,
    win_rate_pct,

    -- Detailed Z-Scores
    z_placement,
    z_top4,
    z_win,
    z_popularity,

    -- Historical Benchmarks & Deltas
    prev_composite_z_score,
    delta_composite_z_score,
    prev_player_popularity_pct,
    delta_player_popularity_pct,
    prev_avg_placement,
    delta_avg_placement,
    prev_top4_rate_pct,
    delta_top4_rate_pct,
    prev_win_rate_pct,
    delta_win_rate_pct,

    -- Context Counters
    unique_players_picked,
    total_items_crafted,
    total_matches,
    total_participants
FROM calculate_patch_deltas
ORDER BY 
    patch_version DESC, 
    item_tier_rank ASC