# -*- coding: utf-8; -*-

import locale
import os.path
import regex
import urllib.parse
import os.path

from collections import Iterable, Mapping  # in Python 3 use from collections.abc
from distutils.spawn import find_executable
from fnmatch import fnmatch
from subprocess import check_output, check_call
from tempfile import NamedTemporaryFile
from TexSoup import TexSoup

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
        return check_output_decode(
            ['mdfind',
             'kMDItemDisplayName=={name}&&kMDItemKind==Application'.format(name=name)]).split('\n')[0]
    except Exception:
        return None

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

LYXPATH = find_executable('lyx') or \
    os.path.join(find_mac_app('LyX'), 'Contents/MacOS/lyx') or \
    '/bin/false'

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

def lyx_bib_deps(lyxfile):
    '''Return an iterator over all bib files referenced by a Lyx file.

    This will only return the names of existing files, so it will be
    unreliable in the case of an auto-generated bib file.

    '''
    with open(lyxfile) as f:
        lyx_text = f.read()
    bib_names = regex.search('bibfiles "(.*?)"', lyx_text).group(1).split(',')
    for bn in bib_names:
        bib_path = bn + '.bib'
        if os.path.exists(bib_path):
            yield bib_path

def lyx_gfx_deps(lyxfile):
    '''Return an iterator over all graphics files included by a LyX file.'''
    with open(lyxfile) as f:
        lyx_text = f.read()
    for m in regex.finditer('\\\\begin_inset Graphics\\s+filename (.*?)$', lyx_text, regex.MULTILINE):
        yield m.group(1)

def lyx_hrefs(lyxfile):
    '''Return an iterator over hrefs in a LyX file.'''
    pattern = '''
    (?xsm)
    ^ LatexCommand \\s+ href \\s* \\n
    (?: name \\b [^\\n]+ \\n )?
    target \\s+ "(.*?)" $
    '''
    with open(lyxfile) as f:
        return (urllib.parse.unquote(m.group(1)) for m in
                re.finditer(pattern, f.read()))

def tex_gfx_extensions(tex_format = 'xetex'):
    '''Return the ordered list of graphics extensions.

    This yields the list of extensions that TeX will try for an
    \\includegraphics path.

    '''
    cmdout = check_output_decode(['texdef', '-t', tex_format, '-p', 'graphicx', 'Gin@extensions'])
    m = regex.search('^macro:->(.*?)$', cmdout, regex.MULTILINE)
    return m.group(1).split(',')

rsync_common_args = ['-rL', '--size-only', '--delete', '--exclude', '.DS_Store', '--delete-excluded',]

rule build_all:
    input: 'thesis.pdf'

# Currently assumes the lyx file always exists.
rule lyx_to_pdf:
    input: lyxfile = '{basename}.lyx',
           gfx_deps = lambda wildcards: lyx_gfx_deps(wildcards.basename + '.lyx'),
           bib_deps = lambda wildcards: lyx_bib_deps(wildcards.basename + '.lyx'),
    # Need to exclude pdfs in graphics/
    output: pdf='{basename,(?!graphics/).*}.pdf'
    shell: '{LYXPATH:q} --export-to pdf4 {output.pdf:q} {input.lyxfile:q}'

# rule create_resume_html:
#     input: lyxfile='ryan_thompson_resume.lyx',
#            bibfiles=list(lyx_bib_deps('ryan_thompson_resume.lyx')),
#            example_files=list(resume_example_deps('ryan_thompson_resume.lyx')),
#            headshot='headshot-crop.jpg',
#     output: html='ryan_thompson_resume.html'
#     run:
#         with NamedTemporaryFile() as tempf:
#             shell('{LYXPATH:q} --export-to xhtml {tempf.name:q} {input.lyxfile:q}')
#             shell('''cat {tempf.name:q} | perl -lape 's[<span class="flex_cv_image">(.*?)</span>][<span class="flex_cv_image"><img src="$1" width="100"></span>]g' > {output.html:q}''')

rule R_to_html:
    input: '{dirname}/{basename,[^/]+}.R'
    output: '{dirname}/{basename}.R.html'
    shell: 'pygmentize -f html -O full -l R -o {output:q} {input:q}'