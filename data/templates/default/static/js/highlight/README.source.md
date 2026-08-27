# highlight.js (vendored)

This directory contains a trimmed, verbatim copy of
[highlight.js](https://github.com/highlightjs/highlight.js), used to colour the metadata
dump on the per-package pages.

| | |
|---|---|
| Upstream | https://github.com/highlightjs/highlight.js |
| Version | 11.12.0 |
| Git tag | `11.12.0` (commit `f7f7d3803bd898e37c017ffb881317f0cde04a70`) |
| License | BSD-3-Clause - see `LICENSE` |

## Updating

1. Pick a release from https://github.com/highlightjs/highlight.js/releases.
2. Fetch both npm packages at that version and replace, from them:
   * `@highlightjs/cdn-assets`: `es/core.min.js` → `core.min.js`, `es/core.js` → `core.js`,
     `LICENSE` → `LICENSE`
   * `highlight.js`: `es/languages/xml.js` → `xml.js`, `es/languages/yaml.js` → `yaml.js`
3. Update the version, tag and commit in the table above.
4. Check that `static/css/highlight.css` still covers the classes the new version emits.
