# -*- coding: utf-8; -*-

import locale
import os.path
import regex
import urllib.parse
import os.path
import bibtexparser
import pypandoc

from collections.abc import Iterable, Mapping
from distutils.spawn import find_executable
from fnmatch import fnmatch
from subprocess import check_output, check_call
from tempfile import NamedTemporaryFile
from bibtexparser.bibdatabase import BibDatabase
from lxml import html
from snakemake.utils import min_version

min_version('3.7.1')

try:
    from os import scandir, walk
except ImportError:
    from scandir import scandir, walk

def unnest(*args):
    '''Un-nest list- and tuple-like elements in arguments.

"List-like" means anything with a len() and whose elments can be
accessed with numeric indexing, except for string-like elements. It
must also be an instance of the collections.Iterable abstract class.
Dict-like elements and iterators/generators are not affected.

This function always returns a list, even if it is passed a single
scalar argument.

    '''
    result = []
    for arg in args:
        if isinstance(arg, str):
            # String
            result.append(arg)
        elif isinstance(arg, Mapping):
            # Dict-like
            result.append(arg)
        elif isinstance(arg, Iterable):
            try:
                # Duck-typing test for list-ness (a stricter condition
                # than just "iterable")
                for i in range(len(arg)):
                    result.append(arg[i])
            except TypeError:
                # Iterable but not list-like
                result.append(arg)
        else:
            # Not iterable
            result.append(arg)
    return result

def check_output_decode(*args, encoding=locale.getpreferredencoding(), **kwargs):
    '''Shortcut for check.output + str.decode'''
    return check_output(*args, **kwargs).decode(encoding)

def find_mac_app(name):
    try:
        result = \
            check_output_decode(
                ['mdfind',
                'kMDItemDisplayName=={name}.app&&kMDItemKind==Application'.format(name=name)]).split('\n')[0] or \
            check_output_decode(
                ['mdfind',
                 'kMDItemDisplayName=={name}&&kMDItemKind==Application'.format(name=name)]).split('\n')[0]
        if result:
            return result
        else:
            raise Exception("Not found")
    except Exception:
        return None

def find_lyx():
    lyx_finders = [
        lambda: find_executable('lyx'),
        lambda: os.path.join(find_mac_app('LyX'), 'Contents/MacOS/lyx'),
        lambda: '/Applications/Lyx.app/Contents/MacOS/lyx',
    ]
    for finder in lyx_finders:
        try:
            lyxpath = finder()
            if not lyxpath:
                continue
            elif not os.access(lyxpath, os.X_OK):
                continue
            else:
                return lyxpath
        except Exception:
            pass
    else:
        # Fallback which will just trigger an error when run (we don't
        # want to trigger an error now, while building the rules)
        return '/bin/false'

LYX_PATH = find_lyx()
PDFINFO_PATH = find_executable('pdfinfo')

def glob_recursive(pattern, top='.', include_hidden=False, *args, **kwargs):
    '''Combination of glob.glob and os.walk.

Reutrns the relative path to every file or directory matching the
pattern anywhere in the specified directory hierarchy. Defaults to the
current working directory. Any additional arguments are passed to
os.walk.'''
    for (path, dirs, files) in walk(top, *args, **kwargs):
        for f in dirs + files:
            if include_hidden or f.startswith('.'):
                continue
            if fnmatch(f, pattern):
                yield os.path.normpath(os.path.join(path, f))

def rsync_list_files(*paths, extra_rsync_args=(), include_dirs=False):
    '''Iterate over the files in path that rsync would copy.

By default, only files are listed, not directories, since doit doesn't
like dependencies on directories because it can't hash them.

This uses "rsync --list-only" to make rsync directly indicate which
files it would copy, so any exclusion/inclusion rules are taken into
account.

    '''
    rsync_list_cmd = [ 'rsync', '-r', '--list-only' ] + unnest(extra_rsync_args) + unnest(paths) + [ '.' ]
    rsync_out = check_output_decode(rsync_list_cmd).splitlines()
    for line in rsync_out:
        s = regex.search('^(-|d)(?:\S+\s+){4}(.*)', line)
        if s is not None:
            if include_dirs or s.group(1) == '-':
                yield s.group(2)

def lyx_input_deps(lyxfile):
    '''Return an iterator over all tex files included by a Lyx file.'''
    try:
        with open(lyxfile) as f:
            lyx_text = f.read()
        for m in regex.finditer('\\\\(?:input|loadglsentries){(.*?[.]tex)}', lyx_text):
            yield m.group(1)
    except FileNotFoundError:
        pass

def lyx_bib_deps(lyxfile):
    '''Return an iterator over all bib files referenced by a Lyx file.

    This will only return the names of existing files, so it will be
    unreliable in the case of an auto-generated bib file.

    '''
    try:
        with open(lyxfile) as f:
            lyx_text = f.read()
        bib_names = regex.search('bibfiles "(.*?)"', lyx_text).group(1).split(',')
        # Unfortunately LyX doesn't indicate which bib names refer to
        # files in the current directory and which don't. Currently that's
        # not a problem for me since all my refs are in bib files in the
        # current directory.
        for bn in bib_names:
            bib_path = bn + '.bib'
            yield bib_path
    except FileNotFoundError:
        pass


def lyx_gfx_deps(lyxfile):
    '''Return an iterator over all graphics files included by a LyX file.'''
    try:
        with open(lyxfile) as f:
            lyx_text = f.read()
        for m in regex.finditer('\\\\begin_inset Graphics\\s+filename (.*?)$', lyx_text, regex.MULTILINE):
            yield m.group(1)
    except FileNotFoundError:
        pass

def lyx_hrefs(lyxfile):
    '''Return an iterator over hrefs in a LyX file.'''
    try:
        pattern = '''
        (?xsm)
        ^ LatexCommand \\s+ href \\s* \\n
        (?: name \\b [^\\n]+ \\n )?
        target \\s+ "(.*?)" $
        '''
        with open(lyxfile) as f:
            return (urllib.parse.unquote(m.group(1)) for m in
                    re.finditer(pattern, f.read()))
    except FileNotFoundError:
        pass

def tex_gfx_extensions(tex_format = 'xetex'):
    '''Return the ordered list of graphics extensions.

    This yields the list of extensions that TeX will try for an
    \\includegraphics path.

    '''
    try:
        cmdout = check_output_decode(['texdef', '-t', tex_format, '-p', 'graphicx', 'Gin@extensions'])
        m = regex.search('^macro:->(.*?)$', cmdout, regex.MULTILINE)
        return m.group(1).split(',')
    except FileNotFoundError:
        return ()

def get_mkdn_included_images(fname):
    '''Return list of all images references in a markdown file.'''
    with open(fname) as f:
        tree = html.fromstring(pypandoc.convert_text(f.read(), 'html', format='md'))
    return list(map(str, tree.xpath("//img/@src")))

def get_mkdn_included_pdfs(fname):
    '''Return list of all images references in a markdown file.'''
    with open(fname) as f:
        tree = html.fromstring(pypandoc.convert_text(f.read(), 'html', format='md'))
    return list(map(str, tree.xpath("//embed/@src")))

rsync_common_args = ['-rL', '--size-only', '--delete', '--exclude', '.DS_Store', '--delete-excluded',]

rule build_all:
    input: 'thesis.pdf', 'thesis-final.pdf', 'presentation.pdf'

# Note: Any rule that generates an input LyX file for this rule must
# be marked as a checkpoint. See
# https://snakemake.readthedocs.io/en/stable/snakefiles/rules.html#data-dependent-conditional-execution
rule thesis_lyx_to_pdf:
    '''Produce PDF output for a LyX file.'''
    input: lyxfile = '{basename}.lyx',
           gfx_deps = lambda wildcards: lyx_gfx_deps(wildcards.basename + '.lyx'),
           bib_deps = lambda wildcards: lyx_bib_deps(wildcards.basename + '.lyx'),
           tex_deps = lambda wildcards: lyx_input_deps(wildcards.basename + '.lyx'),
    output: pdf='{basename,thesis.*}.pdf'
    run:
        if not LYX_PATH or LYX_PATH == '/bin/false':
            raise Exception('Path to LyX  executable could not be found.')
        shell('''{LYX_PATH:q} -batch --verbose --export-to pdf4 {output.pdf:q} {input.lyxfile:q}''')
        if PDFINFO_PATH:
            shell('''{PDFINFO_PATH} {output.pdf:q}''')

checkpoint lyx_add_final:
    '''Copy LyX file and add final option.'''
    input: lyxfile = '{basename}.lyx'
    # Ensure we can't get file-final-final-final-final.lyx
    output: lyxtemp = temp('{basename,(?!graphics/).*(?<!-final)}-final.lyx')
    run:
        with open(input.lyxfile, 'r') as infile, \
             open(output.lyxtemp, 'w') as outfile:
            lyx_text = infile.read()
            if not regex.search('\\\\options final', lyx_text):
                lyx_text = regex.sub('\\\\use_default_options true', '\\\\options final\n\\\\use_default_options true', lyx_text)
            outfile.write(lyx_text)

# TODO: Remove all URLs from entries with a DOI
rule process_bib:
    '''Preprocess bib file for LaTeX.

For entries with a DOI, all URLs are stripped, since the DOI already
provides a clickable link. For entries with no DOI, all but one URL is
discarded, since LyX can't handle entries with multiple URLs. The
shortest URL is kept.'''
    input: '{basename}.bib'
    output: '{basename,.*(?<!-PROCESSED)}-PROCESSED.bib'
    run:
        with open(input[0]) as infile:
            bib_db = bibtexparser.load(infile)
        entries = bib_db.entries
        for entry in entries:
            if 'doi' in entry:
                try:
                    del entry['url']
                except KeyError:
                    pass
            else:
                try:
                    entry_urls = regex.split('\\s+', entry['url'])
                    shortest_url = min(entry_urls, key=len)
                    # Need to fix e.g. 'http://www.pubmedcentral.nih.gov/articlerender.fcgi?artid=55329{\\&}tool=pmcentrez{\\&}rendertype=abstract'
                    shortest_url = re.sub('\\{\\\\(.)\\}', '\\1', shortest_url)
                    entry['url'] = shortest_url
                except KeyError:
                    pass
        new_db = BibDatabase()
        new_db.entries = entries
        with open(output[0], 'w') as outfile:
            bibtexparser.dump(new_db, outfile)

rule pdf_extract_page:
    '''Extract a single page from a multi-page PDF.'''
    # Input is a PDF whose basename doesn't already have a page number
    input: pdf = 'graphics/{basename}.pdf'
    output: pdf = 'graphics/{basename}-PAGE{pagenum,[1-9][0-9]*}.pdf'
    run:
        # This could be done with a regex constraint on basename,
        # except that variable width lookbehind isn't supported.
        # Unfortunately, that makes this a runtime error instead of an
        # error during DAG construction.
        if regex.search('-PAGE[0-9]+$', wildcards.basename):
            raise ValueError("Can't extract page from extracted page PDF.")
        shell('pdfseparate -f {wildcards.pagenum:q} -l {wildcards.pagenum:q} {input:q} {output:q}')

rule pdf_crop:
    '''Crop away empty margins from a PDF.'''
    input: pdf = 'graphics/{basename}.pdf'
    output: pdf = 'graphics/{basename,.*(?<!-CROP)}-CROP.pdf'
    shell: 'pdfcrop --resolution 300 {input:q} {output:q}'

rule pdf_raster:
    '''Rasterize PDF to PNG at 600 PPI.

    The largest dimension is scaled '''
    input: pdf = 'graphics/{basename}.pdf'
    output: png = 'graphics/{basename}-RASTER.png'
    shell: 'pdftoppm -singlefile -r 600 {input:q} | convert - {output:q}'

rule pdf_raster_res:
    '''Rasterize PDF to PNG at specific PPI.

    The largest dimension is scaled '''
    input: pdf = 'graphics/{basename}.pdf'
    output: png = 'graphics/{basename}-RASTER{res,[1-9][0-9]+}.png'
    shell: 'pdftoppm -singlefile -r {wildcards.res} {input:q} | convert - {output:q}'

rule png_crop:
    '''Crop away empty margins from a PNG.'''
    input: pdf = 'graphics/{basename}.png'
    output: pdf = 'graphics/{basename,.*(?<!-CROP)}-CROP.png'
    shell: 'convert {input:q} -trim {output:q}'

rule jpg_crop:
    '''Crop away empty margins from a JPG.'''
    input: pdf = 'graphics/{basename}.jpg'
    output: pdf = 'graphics/{basename,.*(?<!-CROP)}-CROP.jpg'
    shell: 'convert {input:q} -trim {output:q}'

rule svg_to_pdf:
    input: 'graphics/{filename}.svg'
    output: 'graphics/{filename}-SVG.pdf'
    run:
        infile = os.path.join(os.path.abspath("."), input[0])
        outfile = os.path.join(os.path.abspath("."), output[0])
        shell('''inkscape {infile:q} --export-pdf={outfile:q} --export-dpi=300''')

rule svg_raster:
    input: 'graphics/{filename}.svg'
    output: 'graphics/{filename}-SVG.png'
    run:
        infile = os.path.join(os.path.abspath("."), input[0])
        outfile = os.path.join(os.path.abspath("."), output[0])
        shell('''inkscape {infile:q} --export-png={outfile:q} --export-dpi=300''')

rule R_to_html:
    '''Render an R script as syntax-hilighted HTML.'''
    input: '{dirname}/{basename}.R'
    output: '{dirname}/{basename,[^/]+}.R.html'
    shell: 'pygmentize -f html -O full -l R -o {output:q} {input:q}'

rule build_presentation_beamer:
    input:
        extra_preamble='extra-preamble.latex',
        mkdn_file='{basename}.mkdn',
        images=lambda wildcards: get_mkdn_included_images('{basename}.mkdn'.format(**wildcards)),
        pdfs=lambda wildcards: get_mkdn_included_pdfs('{basename}.mkdn'.format(**wildcards)),
    output:
        pdf='{basename,presentation.*}.pdf'
    params:
        # http://deic.uab.es/~iblanes/beamer_gallery/index_by_theme.html
        theme='Boadilla',
        # https://pandoc.org/MANUAL.html#variables-for-beamer-slides
        aspectratio='169',
    shell: '''
    pandoc \
      -f markdown -t beamer \
      --pdf-engine=xelatex \
      -o {output.pdf:q} \
      -H {input.extra_preamble:q} \
      -V theme:{params.theme:q} \
      -V aspectratio:{params.aspectratio:q} \
      {input.mkdn_file:q}
    '''

rule build_presentation_ppt:
    input:
        extra_preamble='extra-preamble.latex',
        mkdn_file='{basename}.mkdn',
        images=lambda wildcards: get_mkdn_included_images('{basename}.mkdn'.format(**wildcards)),
        pdfs=lambda wildcards: get_mkdn_included_pdfs('{basename}.mkdn'.format(**wildcards)),
    output:
        pptx='{basename,presentation.*}.pptx'
    shell: '''
    pandoc \
      -f markdown -t pptx \
      -o {output.pptx:q} \
      {input.mkdn_file:q}
    '''

rule build_all_presentations:
    input:
        'presentation.pdf',
        'presentation.pptx',

rule make_transplant_organs_graph:
    input:
        Rscript='graphics/presentation/transplants-organ.R',
        data='graphics/presentation/transplants-organ.xlsx',
    output:
        pdf='graphics/presentation/transplants-organ.pdf'

    shell: '''
    Rscript 'graphics/presentation/transplants-organ.R'
    '''
