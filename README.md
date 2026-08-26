# markupz for Erlang

`markupz` converts HTML fragments to Markdown. It uses `z_html_parse` from
[`zotonic_stdlib`](https://hex.pm/packages/zotonic_stdlib) and emits Markdown
compatible with [`markdownz`](https://github.com/zotonic/markdownz).

The converter has three presets:

- `default` converts normal content like the faithful preset, but selects only
  the `body` from a full HTML document, omits `aria-hidden="true"` elements,
  and flattens `role="presentation"` tables. This is the default.
- `faithful` converts HTML with direct Markdown equivalents and keeps other
  elements, document metadata, and presentation markup as raw HTML.
- `email` produces a readable `text/plain` alternative for an HTML email. It
  removes presentation HTML, hidden content, and images, flattens tables, and
  puts link destinations after their labels.

## Usage

```erlang
1> markupz:to_markdown(<<"<h1>Hello</h1><p>Welcome <b>back</b>.</p>">>).
<<"Hello\n=====\n\nWelcome **back**.">>

2> markupz:to_email_text(EmailHtml).
<<"Hello\n\nRead the update <https://example.test/update>.">>
```

`to_markdown/2` accepts a preset atom or an option map:

```erlang
markupz:to_markdown(Html, default).
markupz:to_markdown(Html, faithful).
markupz:to_markdown(Html, email).
markupz:to_markdown(Html, #{
    mode => default,
    html => strip,
    tables => text,
    links => inline
}).
```

The options are:

| Option   | Values                         | Default    | Faithful   | Email      |
|----------|--------------------------------|------------|------------|------------|
| `mode`   | `default`, `faithful`, `email` | `default`  | `faithful` | `email`    |
| `html`   | `keep`, `strip`                | `keep`     | `keep`     | `strip`    |
| `tables` | `markdown`, `text`             | `markdown` | `markdown` | `text`     |
| `links`  | `markdown`, `inline`           | `markdown` | `markdown` | `inline`   |

An option map is merged over the defaults of its `mode`. For callers that do
not want exceptions, `convert/1,2` returns `{ok, Markdown}` or
`{error, Reason}`. `to_markdown/1,2` raises `error({invalid_html, Reason})` on
invalid input or options.

## Conversion behavior

The default and faithful presets convert headings, paragraphs, hard breaks,
emphasis, strong text, strikethrough, subscript, superscript, links, images,
inline and fenced code, block quotes, nested ordered and unordered lists,
task-list checkboxes, thematic breaks, and regular tables.

HTML that cannot be represented without losing structure or attributes is
serialized as raw HTML when `html => keep`. For example, a `div` with classes
and a table with `rowspan` or `colspan` remain HTML. With `html => strip`, the
wrapper is removed and its readable content is retained.

When using the default preset:

- a full document containing a `body` element contributes only that body's
  children; fragments without a `body` are converted in full;
- elements with `aria-hidden="true"` and their children are omitted;
- tables with `role="presentation"` are flattened into readable text while
  normal data tables remain Markdown tables.

The email preset additionally:

- omits `head`, `script`, `style`, `template`, SVG, and related non-content;
- omits elements with `hidden`, `aria-hidden="true"`, `display:none`,
  `visibility:hidden`, or `mso-hide:all`;
- turns nested layout tables into text flow and simple multi-column rows into
  `cell | cell` lines;
- writes links as `label <destination>` and omits images entirely;
- renders headings without Markdown decoration.

The converter parses but does not sanitize input. Raw HTML output is deliberate
when `html => keep`; sanitize untrusted HTML before displaying the generated
Markdown with raw HTML enabled.

## Build

```shell
make compile
make test
make xref
make dialyzer
```

For the Zotonic email path, the old call:

```erlang
z_markdown:to_markdown(Html, [no_html, no_tables])
```

can be replaced with:

```erlang
markupz:to_email_text(Html)
```
