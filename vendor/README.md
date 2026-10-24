# Offline rendering dependencies

These files are the native app's pinned WKWebView dependencies. The app and its
build do not download scripts or fonts from a CDN. Preview, selected references
and AI replies use the same rendering stack.

| Package | Version | License supplied here |
| --- | --- | --- |
| lucide | 1.17.0 | ISC and MIT; retain both notices |
| markdown-it | 14.1.0 | MIT |
| highlight.js | 11.11.1 | BSD-3-Clause |
| DOMPurify | 3.4.17 | Apache-2.0 |
| markdown-it-task-lists | 2.1.1 | ISC |
| markdown-it-footnote | 4.0.0 | MIT |
| markdown-it-texmath | 1.0.0 | MIT |
| KaTeX, stylesheet and fonts | 0.19.0 | MIT |
| Mermaid | 12.2.0 | MIT; retain embedded third-party notices |

`assets.json` records package versions, original download and license URLs, and
SHA-256 checksums for every bundled script, license, stylesheet and font. Packaged
files must match this manifest. KaTeX's stylesheet intentionally retains only
WOFF2 font sources for the iOS 26 baseline; its fonts are unchanged upstream files.

`scripts/build_native_web.py` checks the checksums before packaging. License files
are copied alongside the libraries in `JustMarkdown/Resources/Web` and into the
app. Mermaid's bundled license-information comment is part of the original
script and must remain intact. DOMPurify is distributed here under its upstream
Apache-2.0 option. Project licensing does not replace these dependency licenses.

To update a dependency, review its upstream release and security advisories,
replace the script and license together, update the version, URLs and checksums,
then regenerate resources and run both simulator families. A checksum identifies
the reviewed bytes; it does not establish that a dependency has no vulnerabilities.
