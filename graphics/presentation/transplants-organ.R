#!/usr/bin/env Rscript

library(rctutils)
library(scriptName)
library(openxlsx)
library(forcats)
library(tidyverse)

tryCatch(
    setwd(dirname(current_filename())),
    error=function(...) warning("Could not find script path. Hopefully you are in the right directory already."))

organ_data <- read.xlsx("transplants-organ.xlsx") %>%
    arrange(desc(Count)) %>%
    mutate(Organ=fct_inorder(Organ))

p <- ggplot(organ_data) + aes(x=Organ, y=Count, fill=Organ) +
    geom_col() +
    geom_text(aes(label=str_c("  ", Organ, " (", Count, ")   "), hjust=ifelse(Count>max(Count)/2, 1, 0)), vjust=0.5) +
    coord_flip() + scale_x_discrete(limits = rev(levels(organ_data$Organ))) +
    scale_y_continuous(expand=expand_scale(mult=c(0, 0.01))) +
    guides(fill=FALSE) +
    theme(axis.text.y=element_blank(),
          axis.ticks.y=element_blank()) +
    ylab("Transplants performed")
ggprint(p, pdf("transplants-organ.pdf", width=6, height=3))
