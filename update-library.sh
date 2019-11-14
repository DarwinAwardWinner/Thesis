#!/bin/bash
set -euo pipefail

curl http://127.0.0.1:23119/better-bibtex/library\?/1/library.biblatex > library.bibtemp;
if [ "$?" = 0 ]; then
    mv library.bibtemp library.bib
    echo "Updated library.bib from Zotero"
else
    echo "Failed to udpate library.bib from Zotero."
fi
