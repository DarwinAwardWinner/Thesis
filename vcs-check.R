#!/usr/bin/env Rscript

library(magrittr)
library(dplyr)
library(stringr)
library(processx)
library(readr)

get_lines <- . %>%
    str_replace("\n+$", "") %>%
    str_split_fixed(pattern="\n", n=Inf) %>%
    as.vector

git_tracked_files <-
    run("git", c("ls-tree", "-r", "HEAD", "--name-only")) %$%
    stdout %>% get_lines

snakemake_untracked_files <-
    run("snakemake", "--list-untracked") %$%
    stderr %>% get_lines

all_files <- list.files(".", full.names=TRUE, recursive=TRUE) %>%
    str_replace("^./", "")

snakemake_summary <-
    run("snakemake", "--summary") %$%
    stdout %>% read_tsv

snakemake_generated_files <- snakemake_summary$output_file

## All files used as inputs to the snakemake workflow
input_files <- setdiff(all_files, c(snakemake_untracked_files, snakemake_generated_files))

untracked_input_files <- setdiff(input_files, git_tracked_files) %>% sort

if (length(untracked_input_files) > 0) {
    message("The following files are used as input but not tracked in git:\n",
            str_c(untracked_input_files, collapse="\n"))
    quit(status=1)
} else {
    message("All input files used in the workflow are tracked in git.")
}
