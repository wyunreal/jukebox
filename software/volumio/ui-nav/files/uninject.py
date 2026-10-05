#!/usr/bin/env python3
"""Strip the jukebox-ui-nav loader <script> from the Volumio UI pages."""
import glob
import re

pat = re.compile(r'<script id="jk-ui-nav-loader">.*?</script>')
for f in glob.glob("/volumio/http/www*/index.html"):
    try:
        s = open(f, encoding="utf-8").read()
    except OSError:
        continue
    n = pat.sub("", s)
    if n != s:
        open(f, "w", encoding="utf-8").write(n)
        print("cleaned " + f)
