% Generated by roxygen2: do not edit by hand
% Please edit documentation in R/score_calculations.R
\name{calculate_scdai}
\alias{calculate_scdai}
\title{calculate_scdai}
\usage{
calculate_scdai(observations)
}
\arguments{
\item{observations}{observation table usually uploaded using load_data}
}
\value{
A dataframe with all sCDAI scores from eCRF and Smartform regardless of IBD diagnosis.
}
\description{
Calculates short CDAI score from SPARC data.
}
