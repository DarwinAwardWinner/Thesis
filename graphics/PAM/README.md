(This was written back in 2013, and I can't necessarily vouch for any
of the claims within it.)

# Questions

* Overarching question: Can we accurately distinguish AR from TX?
* Can we work well in "clinical" mode, i.e. classifying single samples?
  * How to normalize new sample with training set?
  * How to avoid recalculating classifier for each sample?
* Can we perform well on an external validation set (GEO data)?
  * Are the same genes predictive in both datasets?
  * Can a classifier trained on our data perform well on GEO data?

# Experiments

* pam-analysis.R 
    * How important is it to normalize to the training set? (RMA separate vs together)
    * Conclusion: must normalize together. Separate introduced bias
      toward one class or the other.
    * Question: how to do it with a single sample?
* pam-analysis-norm.R
    * Can single-channel normalization improve classification results? Yes.
    * Try PAM with RMA and two single-channel normalizations
    * fRMA improves cross-dataset accuracy from 65% to 71%.
* limma-analysis-norm.R
    * What is the source of the variation
