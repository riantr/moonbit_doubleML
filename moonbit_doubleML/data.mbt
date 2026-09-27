///|
/// Container for the data consumed by a DML model. Mirrors the subset
/// of `doubleml.DoubleMLData` that the PLR model needs: a feature
/// matrix `x`, an outcome vector `y`, and a (possibly vector) treatment
/// vector `d`. Multi-column treatment is currently treated as a single
/// column vector in the port (the public `DoubleMLPLR` API takes a
/// single treatment, matching the `generate_data_simple` example).
///
/// When `cluster_vars` is non-empty, the model routes through the
/// *clustered* DML path: folds are drawn over the unique unit ids
/// in `cluster_vars` (not over individual rows), the causal parameter
/// is the fold-weighted ratio of cluster score sums, and the
/// variance is the unit-level cluster-robust estimator
/// (`_var_est`'s one-cluster-variable branch). Each row must
/// carry exactly one cluster id; the length of `cluster_vars` is
/// `n_obs`. This mirrors the upstream `DoubleMLData(cluster_cols=)`
/// API in 0.11.x and is the path `DoubleMLClusterData` (the
/// pre-0.11 backward-compat shim) used to take.
pub struct DoubleMLData {
  x : Matrix
  y : Array[Double]
  d : Array[Double]
  cluster_vars : Array[Int]
  // v0.55.0: optional instrument vector Z (length n_obs). Pass
  // a non-empty `z` to enable the IV-type DML score on
  // `DoubleMLPLR`; pass `[]` (the default) for the standard
  // partialling-out path. Empty by default to preserve the
  // v0.54.0 surface.
  z : Array[Double]
} derive(Debug)

///|
pub extend DoubleMLData with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Build a `DoubleMLData` from an `n x p` feature matrix, an
/// outcome vector of length `n` and a treatment vector of length
/// `n`. Pass a non-empty `cluster_vars` to enable the clustered
/// DML path; pass `[]` (the default) for the standard row-level
/// path.
pub fn DoubleMLData::new(
  x : Matrix,
  y : Array[Double],
  d : Array[Double],
  cluster_vars? : Array[Int] = [],
  z? : Array[Double] = [],
) -> DoubleMLData {
  try {
    require(x.nrows == y.length())
    require(x.nrows == d.length())
    if cluster_vars.length() > 0 {
      require(cluster_vars.length() == x.nrows)
    }
    if z.length() > 0 {
      require(z.length() == x.nrows)
    }
    { x, y, d, cluster_vars, z, }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Number of observations in the data.
pub fn DoubleMLData::n_obs(self : DoubleMLData) -> Int {
  self.x.nrows
}

///|
/// Number of features (columns of `X`).
pub fn DoubleMLData::n_features(self : DoubleMLData) -> Int {
  self.x.ncols
}

///|
/// True iff the data is set up for clustered inference (a
/// non-empty `cluster_vars` vector was passed to `new`).
pub fn DoubleMLData::is_cluster_data(self : DoubleMLData) -> Bool {
  self.cluster_vars.length() > 0
}

///|
/// Length of the cluster_vars vector (0 when not clustered).
pub fn DoubleMLData::n_cluster_vars(self : DoubleMLData) -> Int {
  self.cluster_vars.length()
}

///|
/// v0.55.0: instrument vector Z (length `n_obs`) for the
/// IV-type DML score on `DoubleMLPLR`. Returns an empty
/// array when no instrument was passed to `new`.
pub fn DoubleMLData::z(self : DoubleMLData) -> Array[Double] {
  self.z
}

///|
/// True iff the data is set up for IV-type DML (a non-empty
/// `z` vector was passed to `new`). The IV-type score on
/// `DoubleMLPLR::fit(score="IV-type")` requires this; calling
/// `fit` with `score="IV-type"` and no instrument aborts.
pub fn DoubleMLData::is_instrument_data(self : DoubleMLData) -> Bool {
  self.z.length() > 0
}
