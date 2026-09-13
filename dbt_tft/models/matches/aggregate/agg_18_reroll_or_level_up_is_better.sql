{{ config(
    materialized='table',
    schema='agg_matches'
) }}

WITH comp_base AS (
    SELECT
        patch_version,
        comp_key,
        comp_archetype,
        tier_label,
        avg_placement,
        top4_rate_pct,
        win_rate_pct,
        unique_players_picked,
        unique_matches_picked,
        total_matches,
        total_participants
    FROM {{ ref('agg_18_meta_comps') }}
    WHERE patch_version != 'Unknown'
),

-- 1. Classify macro operational playstyle based on tactical archetype naming convention
macro_playstyle_classification AS (
    SELECT
        patch_version,
        comp_key,
        tier_label,
        avg_placement,
        top4_rate_pct,
        win_rate_pct,
        unique_players_picked,
        unique_matches_picked,
        total_matches,
        total_participants,
        
        CASE
            -- Fast 8/9 standard and capped legendary boards (4-5 cost focus)
            WHEN comp_archetype ILIKE '%Fast%' OR comp_archetype ILIKE '%Standard (Fast 8)%' 
                THEN 'Fast 8/9 Standard (4-5 Cost)'
            
            -- Low-cost reroll hyper-roll architectures (1-2-3 cost focus)
            WHEN comp_archetype ILIKE '%Reroll%' 
                THEN 'Reroll Strategy (1-2-3 Cost)'
                
            ELSE 'Standard Flex / Hybrid'
        END AS macro_archetype
        
    FROM comp_base
),

-- 2. Aggregate weighted performance benchmarks and playstyle-level popularity
macro_raw_aggregates AS (
    SELECT
        patch_version,
        macro_archetype,

        -- Diversity & Volume Counters
        COUNT(DISTINCT comp_key)                                       AS total_viable_comps,
        COUNT(CASE WHEN tier_label = 'S-Tier' THEN 1 END)              AS s_tier_comps_count,
        COUNT(CASE WHEN tier_label IN ('S-Tier', 'A-Tier') THEN 1 END) AS top_tier_comps_count,
        SUM(unique_players_picked)                                     AS unique_players_picked,
        SUM(unique_matches_picked)                                     AS unique_matches_picked,

        -- Standalone Popularity Rates per Macro Playstyle
        ROUND(
            SUM(unique_players_picked) * 100.0 / NULLIF(MAX(total_participants), 0),
            4
        ) AS player_popularity_pct,
        ROUND(
            SUM(unique_matches_picked) * 100.0 / NULLIF(MAX(total_matches), 0),
            4
        ) AS match_popularity_pct,

        -- Volume-Weighted Empirical Performance Rates
        ROUND(
            SUM(avg_placement * unique_players_picked) / NULLIF(SUM(unique_players_picked), 0),
            4
        ) AS weighted_avg_placement,
        ROUND(
            SUM(top4_rate_pct * unique_players_picked) / NULLIF(SUM(unique_players_picked), 0),
            4
        ) AS weighted_top4_rate_pct,
        ROUND(
            SUM(win_rate_pct * unique_players_picked) / NULLIF(SUM(unique_players_picked), 0),
            4
        ) AS weighted_win_rate_pct

    FROM macro_playstyle_classification
    WHERE macro_archetype != 'Standard Flex / Hybrid'
    GROUP BY 
        patch_version, 
        macro_archetype
),

-- 3. Final projection maintaining standardized precision and clean presentation
final_macro_comparison AS (
    SELECT
        patch_version,
        macro_archetype,
        total_viable_comps,
        s_tier_comps_count,
        top_tier_comps_count,
        unique_players_picked,
        unique_matches_picked,

        -- Macro Playstyle Market Popularity
        ROUND(player_popularity_pct, 2) AS player_popularity_pct,
        ROUND(match_popularity_pct, 2)  AS match_popularity_pct,

        -- Standardized Core Performance Metrics
        ROUND(weighted_avg_placement, 2) AS avg_placement,
        ROUND(weighted_top4_rate_pct, 2) AS top4_rate_pct,
        ROUND(weighted_win_rate_pct, 2)  AS win_rate_pct

    FROM macro_raw_aggregates
)

SELECT
    patch_version,
    macro_archetype,
    total_viable_comps,
    s_tier_comps_count,
    top_tier_comps_count,
    unique_players_picked,
    unique_matches_picked,
    player_popularity_pct,
    match_popularity_pct,
    avg_placement,
    top4_rate_pct,
    win_rate_pct
FROM final_macro_comparison
ORDER BY 
    patch_version DESC, 
    avg_placement ASC