%% Copyright 2026 Marc Worrell
%% SPDX-License-Identifier: Apache-2.0
-module(markupz_tests).

-include_lib("eunit/include/eunit.hrl").

basic_markdown_test() ->
    Html = <<
        "<h1>Hello</h1>\n",
        "<p>This is <strong>important</strong> &amp; <em>useful</em>.<br> Next.</p>"
    >>,
    ?assertEqual(
        <<"Hello\n=====\n\nThis is **important** & *useful*.  \nNext.">>,
        markupz:to_markdown(Html)).

default_full_document_test() ->
    Html = <<
        "<!doctype html><html><head><title>Example</title>",
        "<style>body { color: red }</style></head>",
        "<body class=\"message\"><h1>Hello</h1>",
        "<p aria-hidden=\"true\">Hidden</p><p>Visible</p></body></html>"
    >>,
    ?assertEqual(
        <<"Hello\n=====\n\nVisible">>,
        markupz:to_markdown(Html)),
    ?assertEqual(
        <<"<head><title>Fragment</title></head>\n\nVisible">>,
        markupz:to_markdown(<<"<head><title>Fragment</title></head><p>Visible</p>">>)).

default_presentation_table_test() ->
    Html = <<
        "<div class=\"outer-layout\">",
        "<table role=\"presentation\" class=\"email-layout\"><tr>",
        "<td><p>First</p></td><td><p>Second</p></td>",
        "</tr></table>",
        "<p aria-hidden=\"TRUE\">Hidden</p><p>Visible</p>",
        "</div>"
    >>,
    ?assertEqual(
        <<"First | Second\n\nVisible">>,
        markupz:to_markdown(Html)).

remaining_html_test() ->
    Html = <<"<div class=\"box\"><p>Hello</p></div>">>,
    ?assertEqual(Html, markupz:to_markdown(Html)),
    ?assertEqual(<<"Hello">>, markupz:to_markdown(Html, #{html => strip})),
    ?assertEqual(
        <<"<p class=\"lead\">Hello</p>">>,
        markupz:to_markdown(<<"<p class=\"lead\">Hello</p>">>)).

table_test() ->
    Html = <<
        "<table><thead><tr>",
        "<th align=\"left\">Name</th><th align=\"right\">Count</th>",
        "</tr></thead><tbody><tr><td>A|B</td><td>12</td></tr></tbody></table>"
    >>,
    ?assertEqual(
        <<
            "| Name | Count |\n",
            "| :--- | ----: |\n",
            "| A\\|B |    12 |"
        >>,
        markupz:to_markdown(Html)).

unrepresentable_table_test() ->
    Html = <<"<table><tr><td colspan=\"2\">Wide</td></tr></table>">>,
    ?assertEqual(Html, markupz:to_markdown(Html)),
    ?assertEqual(<<"Wide">>, markupz:to_email_text(Html)).

email_text_test() ->
    Html = <<
        "<table role=\"presentation\"><tr><td>",
        "<h1>Hello</h1>",
        "<p>Visit <a href=\"https://example.test\">our site</a>.</p>",
        "<img src=\"cid:logo\" alt=\"Logo\">",
        "</td></tr></table>",
        "<div hidden>hidden</div>",
        "<div style=\"mso-hide: all\">preview</div>"
    >>,
    ?assertEqual(
        <<"Hello\n\nVisit our site <https://example.test>.">>,
        markupz:to_email_text(Html)).

email_data_table_test() ->
    Html = <<
        "<table><tr><th>Name</th><th>Count</th></tr>",
        "<tr><td>Apples</td><td>12</td></tr></table>"
    >>,
    ?assertEqual(
        <<"Name | Count\nApples | 12">>,
        markupz:to_email_text(Html)).

nested_list_test() ->
    Html = <<
        "<ol start=\"3\"><li>one<ul><li>nested</li></ul></li>",
        "<li>two</li></ol>"
    >>,
    ?assertEqual(
        <<"3. one\n   - nested\n4. two">>,
        markupz:to_markdown(Html)).

code_test() ->
    Html = <<
        "<p>Use <code>a`b</code>.</p>",
        "<pre lang=\"erlang\"><code>f() -&gt; `ok`.\n</code></pre>"
    >>,
    ?assertEqual(
        <<"Use `` a`b ``.\n\n```erlang\nf() -> `ok`.\n```">>,
        markupz:to_markdown(Html)).

markdownz_code_attributes_test() ->
    Html = <<
        "<pre lang=\"erlang\" class=\"notranslate\">",
        "<code class=\"notranslate language-erlang\">ok.\n</code></pre>"
    >>,
    ?assertEqual(
        <<"```erlang\nok.\n```">>,
        markupz:to_markdown(Html)).

literal_markdown_test() ->
    Html = <<
        "<p># title</p><p>1. item</p>",
        "<p>literal * _ [x] ~a~ &amp;copy;</p>"
    >>,
    ?assertEqual(
        <<
            "\\# title\n\n",
            "1\\. item\n\n",
            "literal \\* \\_ \\[x\\] \\~a\\~ &amp;copy;"
        >>,
        markupz:to_markdown(Html)).

strip_non_content_test() ->
    Html = <<
        "<script>alert(1)</script>",
        "<style>.red { color: red }</style>",
        "<section><p>Visible</p></section>"
    >>,
    ?assertEqual(<<"Visible">>, markupz:to_markdown(Html, #{html => strip})).

email_structures_test() ->
    Html = <<
        "<dl><dt>Term</dt><dd>Definition</dd></dl>",
        "<table><caption>Totals</caption><tr><th>Name</th><th>N</th></tr>",
        "<tr><td>Apples</td><td>1</td></tr></table>",
        "<p>Name: <input type=\"text\" value=\"ignored\"></p>"
    >>,
    ?assertEqual(
        <<"Term\n\nDefinition\n\nTotals\nName | N\nApples | 1\n\nName:">>,
        markupz:to_email_text(Html)).

inline_comment_test() ->
    ?assertEqual(
        <<"A<!-- note -->B">>,
        markupz:to_markdown(<<"<p>A<!-- note -->B</p>">>)).

options_test() ->
    ?assertEqual(
        {error, {invalid_option, html, discard}},
        markupz:convert(<<"<p>Hello</p>">>, #{html => discard})),
    ?assertError(
        {invalid_html, {invalid_option, mode, text}},
        markupz:to_markdown(<<"<p>Hello</p>">>, text)).

aside_fenced_div_test() ->
    ?assertEqual(
        <<"::: {.aside}\nTangential information.\n:::">>,
        markupz:to_markdown(
            <<"<aside><p>Tangential information.</p></aside>">>)).

note_fenced_div_test() ->
    Html = <<
        "<div class=\"admonition note\" role=\"note\">",
        "<p class=\"first admonition-title\">Escaping</p>",
        "<p class=\"last\">Results are safe.</p>",
        "</div>"
    >>,
    ?assertEqual(
        <<"::: {.note title=\"Escaping\"}\nResults are safe.\n:::">>,
        markupz:to_markdown(Html)).

faithful_generic_fenced_div_test() ->
    Html = <<"<div id=\"sample\" class=\"box\"><p>Hello.</p></div>">>,
    ?assertEqual(
        <<"::: {#sample .box}\nHello.\n:::">>,
        markupz:to_markdown(Html, faithful)),
    ?assertEqual(Html, markupz:to_markdown(Html, default)).
