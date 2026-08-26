# BDD acceptance criteria for mavis/dml
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
