# BDD acceptance criteria for mavis/moonbit_doubleML
#
# NOTE ON EXECUTABILITY: MoonBit has no native Gherkin/Cucumber
# runner (no step-definition ecosystem). These .feature files are
# the *documentation* layer: every scenario below maps 1:1 to an
# executable MoonBit test in this repository (named in each
# scenario's comment). The mapping is verified in the release QA
# battery (_verify/T260-verdict.md). Treat a scenario as failing
# if its mapped MoonBit test fails.

Feature: Multi-period DID gt_combinations keywords
  DoubleMLDIDMulti expands gt_combinations_keyword into
  (g, t_pre, t_eval) triples for staggered adoption panels.

  Background:
    Given a 4-cohort x 4-period staggered panel DGP
    And the never-treated cohort g = 0 exists in the data
    And the true ATT is 1.0 for post-treatment cells only

  Scenario: Standard keyword emits only post-treatment cells
    # mapped to: did_multi_universal_includes_pre_treatment
    When the model is fit with gt_combinations_keyword "standard"
    Then the number of combinations is 3
    And every emitted cell satisfies t_eval > t_pre = g

  Scenario: Universal keyword includes pre-treatment placebos
    # mapped to: did_multi_universal_includes_pre_treatment
    When the model is fit with gt_combinations_keyword "universal"
    Then the number of combinations is 9
    And no emitted cell has cohort g = 0
    And no emitted cell has t_eval = t_pre
    And 6 cells satisfy t_eval < t_pre (placebos)

  Scenario: All keyword aliases universal for panel data
    # mapped to: did_multi_universal_includes_pre_treatment
    When the model is fit with gt_combinations_keyword "all"
    Then the number of combinations is 9

  Scenario: Pre-treatment placebos detect no false effect
    # mapped to: did_multi_universal_pre_treatment_placebo
    When the model is fit with gt_combinations_keyword "universal"
    Then at least one pre-treatment cell exists
    And every pre-treatment cell estimate has absolute value < 1.0

Feature: Repeated K-fold cross-fit stability
  GainStatsSource::from_blp_cv_repeated averages OOF residual
  variance across independent K-fold runs to reduce estimator
  variance on small samples.

  Background:
    Given a fitted DoubleMLBLP on 60 observations with 2 basis columns

  Scenario: Single repeat matches from_blp_cv exactly
    # mapped to: gain_stats_from_blp_cv_repeated_matches_single_when_one_repeat
    When from_blp_cv is computed with n_folds 5 and seed 3141
    And from_blp_cv_repeated is computed with n_folds 5, n_repeats 1, seed 3141
    Then both var_y_residuals vectors agree within 1e-15

  Scenario: Averaging across repeats smooths the estimate
    # mapped to: gain_stats_from_blp_cv_repeated_smooths_estimate
    Given single-rep estimates v_a (seed 3141) and v_b (seed 4242)
    When from_blp_cv_repeated is computed with n_repeats 20
    Then the averaged estimate lies closer to both v_a and v_b
    And the averaged estimate stays positive and finite

  Scenario: Structural contract holds
    # mapped to: gain_stats_from_blp_cv_repeated_basic
    Then var_y_residuals has length equal to the BLP coefficient count
    And all_coef equals the BLP coefficients within 1e-15
    And var_y equals the BLP var_y within 1e-15

Feature: Two-stage FDR corrections
  tsbh / tsby adjust p-values using the Storey m0_hat estimator.

  Scenario: TSBH never inflates relative to BH
    # mapped to: tsbh_p_adjust_handrolled and padjust validators
    Given an arbitrary vector of unadjusted p-values
    When tsbh_p_adjust is applied
    Then every adjusted value is <= the BH-adjusted value plus 1e-12

  Scenario: Storey estimator clamps to valid range
    # mapped to: storey_m0_hat usage in tsbh/tsby paths
    Given all p-values above alpha
    Then m0_hat is clamped to at most m
    Given all p-values at or below alpha
    Then m0_hat is clamped to at least 1.0

  Scenario: Dispatcher accepts statsmodels-style long names
    # mapped to: padjust dispatcher tests in did_multi_test.mbt
    When p_adjust is called with method_name "fdr_tsbh"
    Then the result equals tsbh_p_adjust output

Feature: Static panel partially linear regression (PLPR)
  DoubleMLPLPR transforms a static panel via one of four
  approaches and always runs the clustered DML path: folds
  partition whole units, the coefficient is a fold-weighted
  ratio of cluster score sums, and the SE is unit-level
  cluster-robust (upstream doubleml >= 0.11 semantics).

  Background:
    Given a balanced panel DGP with unit fixed effects correlated
      with the treatment (60 units x 4 periods, true theta = 1.0)

  Scenario: All four approaches recover theta at clustered scale
    # mapped to: plpr_all_approaches_recover_theta
    When cre_general, cre_normal, fd_exact and wg_approx are fit
      with n_folds 2 and seed 3141
    Then every theta lies in [0.9, 1.15]
    And every se lies in [0.004, 0.08] (naive row-level inference
      would report ~0.32-0.36 for the CRE approaches)
    And each CI is symmetric around theta with half-width
      1.959963984540054 * se

  Scenario: Cluster coefficient and variance match hand-computed values
    # mapped to: plpr_est_coef_cluster_reference and plpr_var_est_cluster_reference
    Given a two-fold partition with unit weights w = [1, 1/2]
    Then est_coef_cluster returns -10.5 / -3.5 = 3.0 exactly
    Given four units of two rows with hand-computed score sums
    Then var_est_cluster returns sqrt(3.25 / 36) within 1e-12

  Scenario: No unit spans both sides of a fold
    # mapped to: panic_plpr_too_few_units plus the clustered se
    # scale guard in plpr_all_approaches_recover_theta
    When the unit count is below n_folds
    Then fitting aborts
    And on valid panels every fitted se stays at the clustered scale

  Scenario: Without fixed effects cre_general behaves like a plain PLR
    # mapped to: plpr_no_fe_recovery
    Given the same DGP with alpha scaled to ~0
    When cre_general is fit
    Then theta lies in [0.93, 1.07]

Feature: Cluster-robust inference for PLR/IRM
  Passing a non-empty `cluster_vars` to `DoubleMLData::new`
  routes the estimator through the clustered DML path: folds
  are drawn over the unique unit ids (rows of one unit stay
  on the same side of every split), the causal parameter is
  the fold-weighted ratio of cluster score sums, and the SE
  is unit-level cluster-robust. Mirrors the upstream
  `DoubleMLData(cluster_cols=...)` API in 0.11.x.

  Background:
    Given a clustered panel DGP with strong within-unit
      correlation (50 units x 4 periods, alpha = 0.5)

  Scenario: Cluster-robust SE is larger than the row-level SE
    # mapped to: plr_cluster_se_larger_than_row_se
    When the same data is fit twice — once with cluster_vars
    And once without
    Then the cluster SE is at least 1.5x the row-level SE
    And both theta_hat values are finite

  Scenario: Cluster data accessor returns true only when set
    # mapped to: plr_cluster_data_class, plr_no_cluster_data_default,
    #            plr_explicit_empty_cluster_vars
    Then is_cluster_data is true iff cluster_vars was non-empty
    And n_obs and n_features are unchanged

  Scenario: Same-seed cluster refit is bit-exact
    # mapped to: plr_cluster_deterministic
    When the same data and seed are used twice
    Then coef agrees within 1e-15 and se agrees within 1e-15

  Scenario: Cluster SE / row SE ratio is a lower bound
    # mapped to: plr_cluster_se_ratio_lower_bound
    Given a 60-unit x 5-period clustered panel
    Then the cluster / row SE ratio is at least 1.2

Feature: Partially logistic regression (LPLR)
  DoubleMLLPLR estimates `Y = expit(D * theta + r_0(X))` for binary
  outcomes via a double cross-fit (outer folds for ml_M / ml_m /
  ml_t; inner folds for the preliminary per-fold beta and the
  inner OOF used to build `W = logit(M_inner)`). The score is
  nonlinear in theta; the port uses a damped Newton solve for
  numerical stability on the closed-form-learner DGP.

  Background:
    Given a LZZ2020-style DGP with alpha = 0.5 (60 x 6 features,
      500 observations, binary D and Y)

  Scenario: LPLR recovers alpha at finite positive SE
    # mapped to: lplr_smoke_lzz2020_recovers_theta
    When DoubleMLLPLR is fit with n_folds=2, n_folds_inner=2
    Then theta_hat is finite and theta lies in [-1.0, 2.5]
    And the standard error is positive and finite

  Scenario: LPLR respects both score paths
    # mapped to: lplr_both_scores_accepted
    When the score is set to "nuisance_space"
    And the score is set to "instrument"
    Then both fits complete without aborting

  Scenario: Newton solve at the root converges in one step
    # mapped to: lplr_newton_solve_at_root
    Given psi = 0, psi_deriv = 1 (length 3) and theta_start = 1.0
    When newton_solve_score is called
    Then the result is (1.0, true) within 1e-12

  Scenario: Same-seed refit is deterministic
    # mapped to: lplr_deterministic
    When the same data and seed are used twice
    Then coef agrees within 1e-15 and se agrees within 1e-15

  Scenario: CI identity holds
    # mapped to: lplr_confint_identity
    When the model is fit
    Then (hi - lo) / 2 == 1.959963984540054 * se within 1e-9
    And (hi + lo) / 2 == coef within 1e-12

  Scenario: expit / logit round-trip
    # mapped to: lplr_expit_logit_round_trip
    Then expit(0) == 0.5 within 1e-15
    And logit(0.5) == 0 within 1e-15
    And for x in {-1, -0.5, 0.5, 1, 3}, logit(expit(x)) == x within 1e-9
