#!/usr/bin/env python

import re
import os
import os.path
import sys
import shlex
import pandas
from subprocess import check_output, run, PIPE, DEVNULL
from io import StringIO

def check_output_lines(*args, **kwargs):
    return check_output(*args, **kwargs).rstrip('\n').split('\n')

git_tracked_files = set(check_output_lines(
    ["git", "ls-tree", "-r", "HEAD", "--name-only"],
    text = True))

snakemake_untracked_files = set(run(
    ["snakemake", "--list-untracked"],
    capture_output = True, text = True, check = True
).stderr.rstrip('\n').split('\n'))

all_files = set()
for curdir, subdirs, files in os.walk('.'):
    subdirs[:] = [d for d in subdirs if not d.startswith(".")]
    for f in files:
        if f.startswith('.'):
            continue
        all_files.add(os.path.normpath(os.path.join(curdir, f)))

snakemake_summary_output = check_output(['snakemake', '--summary'], text = True, stderr=DEVNULL)
snakemake_summary_table = pandas.read_csv(StringIO(snakemake_summary_output), sep='\t')
snakemake_generated_files = {os.path.normpath(f) for f in snakemake_summary_table.output_file}

input_files = all_files - (snakemake_untracked_files | snakemake_generated_files)

untracked_input_files = input_files - git_tracked_files

if untracked_input_files:
    print("Untracked input files detected. Run the following command to add them to git:\ngit add " + " ".join(shlex.quote(f) for f in untracked_input_files),
          file=sys.stderr)
    sys.exit(1)
else:
    print("All input files known to be used in the workflow are tracked in git.")
    sys.exit(0)
