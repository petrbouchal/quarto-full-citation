# quarto-full-citation

A Quarto extension that inserts **full formatted citations inline** with the option of packaging PDF attachements — ideal for sharing annotated bibliographies, syllabi, and reading lists.

- HTML output: PDFs referenced in the bib `file` field are copied to the output directory and a **[PDF]** link is appended.
- Input is any `.bib` / `.bibtex` file specified in the `bibliography` YAML field.
- Formatting is done entirely by **citeproc** using any standard CSL file.
- Pure Pandoc + Lua — no R, no Python.

See also [Zotero plugin](https://github.com/petrbouchal/zotero-biblio-html) that does the same thing without Quarto, with less customisation.

## Installation

Copy `_extensions/full-citation/` into your project, or install from GitHub:

```bash
quarto install extension petrbouchal/quarto-full-citation
```

## Front matter

```yaml
---
bibliography: references.bib
csl: chicago-author-date.csl   # any CSL style
nocite: "@*"                   # make all entries available to citeproc
filters:
  - full-citation

# Extension options (defaults shown):
full-citation-suppress-bibliography: false
full-citation-attachments: true
full-citation-all: false
---
```

`nocite: "@*"` is recommended so that citeproc processes every entry and makes
it available to the extension, even if the key does not appear in the document
body.

## Options

### `full-citation-suppress-bibliography`

Controls the auto-generated reference list that Pandoc appends at the end of
the document.

| Value | Effect |
|---|---|
| `false` *(default)* | Trailing reference list is included. |
| `true` | Trailing reference list is removed. |

> **Do not** use Pandoc's own `suppress-bibliography: true` — that disables
> citeproc internally and prevents the extension from building its citation map.

### `full-citation-attachments`

Controls PDF copying and `[PDF]` links. Has no effect on non-HTML output
formats.

| Value | Effect |
|---|---|
| `true` *(default)* | Reads bib `file` fields; copies PDFs to `{bib-name}-attachments/` next to the HTML file; appends `[PDF]` links. |
| `false` | No PDF copying; `[PDF]` links are omitted. `[online]` links are unaffected. |

### `full-citation-all`

Controls whether *every* `[@key]` in the document is expanded.

| Value | Effect |
|---|---|
| `false` *(default)* | Only citations inside `.full-citation` divs are expanded. |
| `true` | **Every** `[@key]` in the document is expanded to a full inline citation (analogous to LaTeX's `\fullcite`). |

`.full-citation` divs and `full-citation-all: true` can be mixed freely; divs
are processed first.

## Citation syntax

### `.full-citation` div

```markdown
:::{.full-citation}
[@citekey]
:::
```

### `ref=` attribute

Use `ref=` when you prefer not to place a cite key inside the div body. The
key must still be known to citeproc — either via `nocite` in the front matter
or by appearing elsewhere in the document as `[@key]`.

```markdown
:::{.full-citation ref="citekey"}
:::
```

### `full-citation-all: true` mode

With this option set, every standard inline citation is automatically expanded:

```markdown
The study by @author2023 shows …   ← renders as full inline citation
```

## `[PDF]` and `[online]` links (HTML output)

Both links are appended inline at the end of each formatted citation.

| Link | Condition |
|---|---|
| `[online]` | `url` field present in the bib entry |
| `[PDF]` | `file` field present **and** `full-citation-attachments: true` |

Supported `file` field formats (JabRef / Zotero):

```
file = {:path/to/paper.pdf:PDF}
file = {Description:path/to/paper.pdf:application/pdf}
file = {/absolute/path/to/paper.pdf}
```

Paths can be absolute or relative to the `.bib` file.

## Typical configurations

### Annotated bibliography

Full citations with PDF links; no trailing reference list.

```yaml
nocite: "@*"
full-citation-suppress-bibliography: true
full-citation-attachments: true
full-citation-all: false
```

Write prose annotations after each `.full-citation` div:

```markdown
:::{.full-citation}
[@smith2023]
:::

Smith argues that …
```

### Syllabus / reading list (all-in-one)

Every `[@key]` expands inline; no `.full-citation` divs required.

```yaml
nocite: "@*"
full-citation-suppress-bibliography: true
full-citation-attachments: false
full-citation-all: true
```

### Reading list with PDFs, keep reference list

```yaml
nocite: "@*"
full-citation-suppress-bibliography: false
full-citation-attachments: true
full-citation-all: false
```

## Rendering

```bash
quarto render example.qmd
```

## Known limitations

- Only the first citation key in a `.full-citation` div is used; one div per entry.
- `full-citation-all` with grouped cites `[@k1; @k2]` expands only the first key.
- PDF attachments work for HTML output only.
- Windows absolute paths in bib `file` fields are not handled.
