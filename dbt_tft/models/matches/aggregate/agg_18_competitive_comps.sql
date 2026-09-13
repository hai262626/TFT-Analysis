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
        main_carry_rarity
    FROM {{ ref('agg_18_int_defining_comps') }}
    WHERE patch_version != 'Unknown'
      AND comp_key NOT LIKE '%NoCarry%'
      AND comp_key NOT LIKE '%NoTrait%'
),

-- 1. Identify lobby congestion by counting co-occurring compositions per match
match_lobby_density AS (
    SELECT
        bc.*,
        COUNT(bc.puuid) OVER (
            PARTITION BY bc.match_id, bc.comp_key
        ) AS players_sharing_comp
    FROM base_comps bc
),

-- 2. Tag contest state per participant record
participant_contest_tagged AS (
    SELECT
        mld.*,
        CASE 
            WHEN mld.players_sharing_comp = 1 THEN 'Uncontested'
            ELSE 'Contested'
        END AS contest_status
    FROM match_lobby_density mld
),

-- 3. Aggregate contest performance benchmarks per composition archetype
comp_contest_aggregates AS (
    SELECT
        patch_version,
        comp_key,
        primary_trait,
        main_carry,
        MAX(main_carry_rarity)                                         AS main_carry_rarity,

        -- Sample volume counters
        COUNT(DISTINCT participant_id)                                 AS total_picks,
        COUNT(DISTINCT match_id)                                       AS total_matches_present,
        COUNT(CASE WHEN contest_status = 'Uncontested' THEN 1 END)     AS uncontested_picks,
        COUNT(CASE WHEN contest_status = 'Contested' THEN 1 END)       AS contested_picks,

        -- Overall baseline performance
        ROUND(AVG(placement), 4)                                       AS overall_avg_placement,
        ROUND(AVG(CASE WHEN placement <= 4 THEN 1.0 ELSE 0.0 END) * 100, 4) AS overall_top4_rate_pct,
        ROUND(AVG(CASE WHEN placement = 1 THEN 1.0 ELSE 0.0 END) * 100, 4)  AS overall_win_rate_pct,

        -- Uncontested performance rates (Solo player in lobby)
        ROUND(AVG(CASE WHEN contest_status = 'Uncontested' THEN placement END), 4) AS uncontested_avg_placement,
        ROUND(AVG(CASE WHEN contest_status = 'Uncontested' AND placement <= 4 THEN 1.0 
                       WHEN contest_status = 'Uncontested' THEN 0.0 END) * 100, 4) AS uncontested_top4_rate_pct,
        ROUND(AVG(CASE WHEN contest_status = 'Uncontested' AND placement = 1 THEN 1.0 
                       WHEN contest_status = 'Uncontested' THEN 0.0 END) * 100, 4) AS uncontested_win_rate_pct,

        -- Contested performance rates (>= 2 players in lobby)
        ROUND(AVG(CASE WHEN contest_status = 'Contested' THEN placement END), 4) AS contested_avg_placement,
        ROUND(AVG(CASE WHEN contest_status = 'Contested' AND placement <= 4 THEN 1.0 
                       WHEN contest_status = 'Contested' THEN 0.0 END) * 100, 4) AS contested_top4_rate_pct,
        ROUND(AVG(CASE WHEN contest_status = 'Contested' AND placement = 1 THEN 1.0 
                       WHEN contest_status = 'Contested' THEN 0.0 END) * 100, 4) AS contested_win_rate_pct

    FROM participant_contest_tagged
    GROUP BY 
        patch_version,
        comp_key,
        primary_trait,
        main_carry
    -- Filter out low-volume compositions to eliminate statistical noise
    HAVING COUNT(DISTINCT participant_id) >= 20
),

-- 4. Calculate contest sensitivity, rate percentages, and placement penalties
final_comp_contested_metrics AS (
    SELECT
        patch_version,
        comp_key,
        primary_trait,
        main_carry,
        main_carry_rarity,

        -- Volume counters
        total_picks,
        total_matches_present,
        uncontested_picks,
        contested_picks,

        -- Contest Frequency (How often does this composition collide in lobbies?)
        ROUND(
            contested_picks * 100.0 / NULLIF(total_picks, 0), 
            2
        ) AS contested_rate_pct,

        -- Overall baseline metrics
        ROUND(overall_avg_placement, 2)   AS overall_avg_placement,
        ROUND(overall_top4_rate_pct, 2)   AS overall_top4_rate_pct,
        ROUND(overall_win_rate_pct, 2)    AS overall_win_rate_pct,

        -- Uncontested breakdown
        ROUND(uncontested_avg_placement, 2) AS uncontested_avg_placement,
        ROUND(uncontested_top4_rate_pct, 2) AS uncontested_top4_rate_pct,
        ROUND(uncontested_win_rate_pct, 2)  AS uncontested_win_rate_pct,

        -- Contested breakdown
        ROUND(contested_avg_placement, 2)   AS contested_avg_placement,
        ROUND(contested_top4_rate_pct, 2)   AS contested_top4_rate_pct,
        ROUND(contested_win_rate_pct, 2)    AS contested_win_rate_pct,

        -- CONTESTED PENALTY DELTA: Positive delta signifies rank deterioration when contested
        ROUND(
            COALESCE(contested_avg_placement, overall_avg_placement) - 
            COALESCE(uncontested_avg_placement, overall_avg_placement), 
            2
        ) AS contested_placement_penalty,

        -- TOP 4 RETENTION DROP: Negative delta signifies top 4 rate drop when contested
        ROUND(
            COALESCE(contested_top4_rate_pct, overall_top4_rate_pct) - 
            COALESCE(uncontested_top4_rate_pct, overall_top4_rate_pct), 
            2
        ) AS contested_top4_delta_pct,

        -- WIN RATE DROP: Negative delta signifies win rate drop when contested
        ROUND(
            COALESCE(contested_win_rate_pct, overall_win_rate_pct) - 
            COALESCE(uncontested_win_rate_pct, overall_win_rate_pct), 
            2
        ) AS contested_win_delta_pct

    FROM comp_contest_aggregates
)

SELECT
    patch_version,
    comp_key,
    primary_trait,
    main_carry,
    main_carry_rarity,
    total_picks,
    total_matches_present,
    uncontested_picks,
    contested_picks,
    contested_rate_pct,
    overall_avg_placement,
    uncontested_avg_placement,
    contested_avg_placement,
    contested_placement_penalty,
    overall_top4_rate_pct,
    uncontested_top4_rate_pct,
    contested_top4_rate_pct,
    contested_top4_delta_pct,
    overall_win_rate_pct,
    uncontested_win_rate_pct,
    contested_win_rate_pct,
    contested_win_delta_pct
FROM final_comp_contested_metrics
ORDER BY 
    patch_version DESC, 
    contested_placement_penalty DESC