#!/usr/bin/env Rscript

library(magrittr)
library(tibble)
library(dplyr)
library(ggplot2)
library(rctutils)

sigdata <- tibble(
    beta = seq(from=1e-6, to=1-1e-6, length.out=500),
    m = log2( beta / (1 - beta)))

p <- ggplot(sigdata) +
    aes(y = m, x = beta) +
    geom_line() +
    coord_cartesian(ylim = c(-6, 6), xlim = c(0, 1)) +
    theme_bw() +
    ylab("M-value") + xlab(expression(paste(beta, "-value")))
ggprint(p, pdf("sigmoid.pdf", width=6, height=8))
