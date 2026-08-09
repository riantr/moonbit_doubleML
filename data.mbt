///|
/// Container for the data consumed by a DML model. Mirrors the subset
/// of `doubleml.DoubleMLData` that the PLR model needs: a feature
/// matrix `x`, an outcome vector `y`, and a (possibly vector) treatment
/// vector `d`. Multi-column treatment is currently treated as a single
/// column vector in the port (the public `DoubleMLPLR` API takes a
/// single treatment, matching the `generate_data_simple` example).
pub struct DoubleMLData {
  x : Matrix
  y : Array[Double]
  d : Array[Double]
} derive(Debug)

///|
/// Build a `DoubleMLData` from an `n x p` feature matrix, an
/// outcome vector of length `n` and a treatment vector of length `n`.
pub fn DoubleMLData::new(
  x : Matrix,
  y : Array[Double],
  d : Array[Double],
) -> DoubleMLData {
  require(x.nrows == y.length())
  require(x.nrows == d.length())
  { x, y, d }
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
