%% Copyright 2026 Marc Worrell
%% SPDX-License-Identifier: Apache-2.0
%% @doc Render a z_html_parse tree as Markdown.
-module(markupz_renderer).

-export([render/2]).

-define(MAX_TABLE_CELL_WIDTH, 80).

-record(ctx, {
    mode :: default | faithful | email,
    html :: keep | strip,
    tables :: markdown | text,
    links :: markdown | inline,
    list_depth = 0 :: non_neg_integer()
}).

-type html_node() :: z_html_parse:html_element().

-spec render([html_node()], map()) -> binary().
render(Nodes, Options) ->
    Context = #ctx{
        mode = maps:get(mode, Options),
        html = maps:get(html, Options),
        tables = maps:get(tables, Options),
        links = maps:get(links, Options)
    },
    z_string:trim(iolist_to_binary(render_nodes(Nodes, Context))).

render_nodes(Nodes, Context) ->
    render_nodes(Nodes, Context, none).

render_nodes([], _Context, _Previous) ->
    [];
render_nodes([Text | Rest], Context, Previous) when is_binary(Text) ->
    case z_string:trim(Text) of
        <<>> ->
            Next = next_non_whitespace(Rest),
            Rendered = case keep_inter_element_space(Previous, Next) of
                true -> <<" ">>;
                false -> []
            end,
            [Rendered | render_nodes(Rest, Context, Previous)];
        _ ->
            Next = next_non_whitespace(Rest),
            Normalized = trim_flow_edges(collapse_whitespace(Text), Previous, Next),
            [markdown_text(Normalized) | render_nodes(Rest, Context, Text)]
    end;
render_nodes([Node | Rest], Context, _Previous) ->
    [render_node(Node, Context) | render_nodes(Rest, Context, Node)].

next_non_whitespace([Text | Rest]) when is_binary(Text) ->
    case z_string:trim(Text) of
        <<>> -> next_non_whitespace(Rest);
        _ -> Text
    end;
next_non_whitespace([Node | _Rest]) -> Node;
next_non_whitespace([]) -> none.

keep_inter_element_space(none, _Next) -> false;
keep_inter_element_space(_Previous, none) -> false;
keep_inter_element_space(Previous, Next) ->
    not breaks_flow(Previous) andalso not breaks_flow(Next).

breaks_flow({Tag, _Attributes, _Children}) -> is_block_tag(Tag) orelse Tag =:= <<"br">>;
breaks_flow(_Node) -> false.

trim_flow_edges(Text, Previous, Next) ->
    Text1 = case breaks_flow(Previous) of
        true -> z_string:trim_left(Text);
        false -> Text
    end,
    case breaks_flow(Next) of
        true -> z_string:trim_right(Text1);
        false -> Text1
    end.

render_node(Text, _Context) when is_binary(Text) ->
    markdown_text(collapse_whitespace(Text));
render_node({comment, Comment}, #ctx{html = keep}) ->
    [<<"<!--">>, Comment, <<"-->">>];
render_node({comment, _Comment}, #ctx{html = strip}) ->
    [];
render_node({'=', Html}, #ctx{html = keep}) ->
    Html;
render_node({'=', _Html}, #ctx{html = strip}) ->
    [];
render_node({Tag, Attributes, Children} = Node, Context) ->
    case is_hidden(Node, Context) of
        true ->
            [];
        false ->
            case is_presentation_table(Tag, Attributes, Context) of
                true -> render_text_table(Children, Context);
                false ->
                    case preserve_as_html(Tag, Attributes, Node, Context) of
                        true -> raw_html(Node, Tag);
                        false -> render_tag(Tag, Attributes, Children, Context)
                    end
            end
    end;
render_node(Node, #ctx{html = keep}) when is_tuple(Node) ->
    block(z_html_parse:to_html(Node));
render_node(_Node, #ctx{html = strip}) ->
    [].

preserve_as_html(_Tag, _Attributes, _Node, #ctx{html = strip}) ->
    false;
preserve_as_html(Tag, Attributes, {Tag, Attributes, Children} = Node,
        #ctx{mode = default, html = keep}) ->
    case contains_default_special_content(Children) of
        true -> false;
        false -> needs_raw_html(Tag, Attributes, Node)
    end;
preserve_as_html(Tag, Attributes, Node, #ctx{html = keep}) ->
    needs_raw_html(Tag, Attributes, Node).

needs_raw_html(Tag, Attributes, Node) ->
    not is_markdown_tag(Tag)
        orelse not supported_attributes(Tag, Attributes)
        orelse not representable_node(Tag, Node).

contains_default_special_content(Nodes) ->
    lists:any(fun is_default_special_content/1, Nodes).

is_default_special_content({<<"table">>, Attributes, _Children} = Node) ->
    is_aria_hidden(Attributes)
        orelse is_presentation_role(Attributes)
        orelse has_default_special_descendant(Node);
is_default_special_content({_Tag, Attributes, _Children} = Node) ->
    is_aria_hidden(Attributes) orelse has_default_special_descendant(Node);
is_default_special_content(_Node) ->
    false.

has_default_special_descendant({_Tag, _Attributes, Children}) ->
    contains_default_special_content(Children).

is_markdown_tag(<<"html">>) -> true;
is_markdown_tag(<<"body">>) -> true;
is_markdown_tag(<<"p">>) -> true;
is_markdown_tag(<<"h1">>) -> true;
is_markdown_tag(<<"h2">>) -> true;
is_markdown_tag(<<"h3">>) -> true;
is_markdown_tag(<<"h4">>) -> true;
is_markdown_tag(<<"h5">>) -> true;
is_markdown_tag(<<"h6">>) -> true;
is_markdown_tag(<<"hr">>) -> true;
is_markdown_tag(<<"br">>) -> true;
is_markdown_tag(<<"em">>) -> true;
is_markdown_tag(<<"i">>) -> true;
is_markdown_tag(<<"strong">>) -> true;
is_markdown_tag(<<"b">>) -> true;
is_markdown_tag(<<"del">>) -> true;
is_markdown_tag(<<"s">>) -> true;
is_markdown_tag(<<"strike">>) -> true;
is_markdown_tag(<<"sub">>) -> true;
is_markdown_tag(<<"sup">>) -> true;
is_markdown_tag(<<"a">>) -> true;
is_markdown_tag(<<"img">>) -> true;
is_markdown_tag(<<"code">>) -> true;
is_markdown_tag(<<"pre">>) -> true;
is_markdown_tag(<<"blockquote">>) -> true;
is_markdown_tag(<<"ul">>) -> true;
is_markdown_tag(<<"ol">>) -> true;
is_markdown_tag(<<"li">>) -> true;
is_markdown_tag(<<"table">>) -> true;
is_markdown_tag(<<"input">>) -> true;
is_markdown_tag(_) -> false.

supported_attributes(<<"a">>, Attributes) ->
    only_attributes(Attributes, [<<"href">>, <<"title">>]);
supported_attributes(<<"img">>, Attributes) ->
    only_attributes(Attributes, [<<"src">>, <<"alt">>, <<"title">>]);
supported_attributes(<<"ol">>, Attributes) ->
    only_attributes(Attributes, [<<"start">>]);
supported_attributes(<<"pre">>, Attributes) ->
    only_attributes(Attributes, [<<"lang">>, <<"class">>]) andalso
        supported_pre_class(proplists:get_value(<<"class">>, Attributes));
supported_attributes(<<"table">>, Attributes) ->
    lists:all(fun supported_table_attribute/1, Attributes);
supported_attributes(<<"input">>, Attributes) ->
    is_checkbox(Attributes) andalso
        only_attributes(Attributes, [<<"type">>, <<"checked">>, <<"disabled">>]);
supported_attributes(_Tag, []) ->
    true;
supported_attributes(_Tag, _Attributes) ->
    false.

supported_table_attribute({<<"role">>, <<"table">>}) -> true;
supported_table_attribute({<<"class">>, <<"table">>}) -> true;
supported_table_attribute(_) -> false.

representable_node(<<"table">>, Node) -> table_is_representable(Node);
representable_node(<<"pre">>, {<<"pre">>, _Attributes, Children}) ->
    pre_is_representable(Children);
representable_node(_Tag, _Node) -> true.

only_attributes(Attributes, Allowed) ->
    lists:all(
        fun({Name, _Value}) -> lists:member(Name, Allowed) end,
        Attributes).

render_tag(<<"html">>, _Attributes, Children, Context) ->
    render_nodes(Children, Context);
render_tag(<<"body">>, _Attributes, Children, Context) ->
    render_nodes(Children, Context);
render_tag(<<"p">>, _Attributes, Children, Context) ->
    paragraph(render_nodes(Children, Context));
render_tag(<<"h", Level>>, _Attributes, Children, #ctx{mode = Mode} = Context)
        when (Mode =:= default orelse Mode =:= faithful), Level >= $1, Level =< $6 ->
    heading(Level - $0, render_nodes(Children, Context));
render_tag(<<"h", Level>>, _Attributes, Children, #ctx{mode = email} = Context)
        when Level >= $1, Level =< $6 ->
    paragraph(render_nodes(Children, Context));
render_tag(<<"hr">>, _Attributes, _Children, #ctx{mode = Mode})
        when Mode =:= default; Mode =:= faithful ->
    block(<<"---">>);
render_tag(<<"hr">>, _Attributes, _Children, #ctx{mode = email}) ->
    block(<<"----------------------------------------">>);
render_tag(<<"br">>, _Attributes, _Children, #ctx{mode = Mode})
        when Mode =:= default; Mode =:= faithful ->
    <<"  \n">>;
render_tag(<<"br">>, _Attributes, _Children, #ctx{mode = email}) ->
    <<"\n">>;
render_tag(<<"em">>, _Attributes, Children, Context) ->
    wrap_inline(<<"*">>, render_nodes(Children, Context));
render_tag(<<"i">>, _Attributes, Children, Context) ->
    wrap_inline(<<"*">>, render_nodes(Children, Context));
render_tag(<<"strong">>, _Attributes, Children, Context) ->
    wrap_inline(<<"**">>, render_nodes(Children, Context));
render_tag(<<"b">>, _Attributes, Children, Context) ->
    wrap_inline(<<"**">>, render_nodes(Children, Context));
render_tag(<<"del">>, _Attributes, Children, Context) ->
    wrap_inline(<<"~~">>, render_nodes(Children, Context));
render_tag(<<"s">>, _Attributes, Children, Context) ->
    wrap_inline(<<"~~">>, render_nodes(Children, Context));
render_tag(<<"strike">>, _Attributes, Children, Context) ->
    wrap_inline(<<"~~">>, render_nodes(Children, Context));
render_tag(<<"sub">>, _Attributes, Children, Context) ->
    wrap_inline(<<"~">>, render_nodes(Children, Context));
render_tag(<<"sup">>, _Attributes, Children, Context) ->
    wrap_inline(<<"^">>, render_nodes(Children, Context));
render_tag(<<"a">>, Attributes, Children, Context) ->
    render_link(Attributes, Children, Context);
render_tag(<<"img">>, Attributes, _Children, Context) ->
    render_image(Attributes, Context);
render_tag(<<"code">>, _Attributes, Children, _Context) ->
    render_code_span(Children);
render_tag(<<"pre">>, Attributes, Children, Context) ->
    render_code_block(Attributes, Children, Context);
render_tag(<<"blockquote">>, _Attributes, Children, Context) ->
    quote(render_nodes(Children, Context));
render_tag(<<"ul">>, _Attributes, Children, Context) ->
    render_list(unordered, 1, Children, Context);
render_tag(<<"ol">>, Attributes, Children, Context) ->
    render_list(ordered, ordered_start(Attributes), Children, Context);
render_tag(<<"li">>, _Attributes, Children, Context) ->
    render_nodes(Children, Context);
render_tag(<<"table">>, _Attributes, Children, #ctx{tables = markdown} = Context) ->
    render_markdown_table(Children, Context);
render_tag(<<"table">>, _Attributes, Children, #ctx{tables = text} = Context) ->
    render_text_table(Children, Context);
render_tag(<<"input">>, Attributes, _Children, _Context) ->
    case is_checkbox(Attributes) of
        true ->
            case proplists:is_defined(<<"checked">>, Attributes) of
                true -> <<"[x] ">>;
                false -> <<"[ ] ">>
            end;
        false -> []
    end;
render_tag(Tag, _Attributes, _Children, _Context) when
        Tag =:= <<"head">>;
        Tag =:= <<"script">>;
        Tag =:= <<"style">>;
        Tag =:= <<"template">>;
        Tag =:= <<"title">>;
        Tag =:= <<"meta">>;
        Tag =:= <<"link">>;
        Tag =:= <<"base">>;
        Tag =:= <<"svg">> ->
    [];
render_tag(Tag, _Attributes, Children, Context) when Tag =:= <<"dt">>; Tag =:= <<"dd">> ->
    paragraph(render_nodes(Children, Context));
render_tag(Tag, _Attributes, Children, Context) ->
    Rendered = render_nodes(Children, Context),
    case is_block_tag(Tag) of
        true -> paragraph(Rendered);
        false -> Rendered
    end.

paragraph(Content) ->
    case z_string:trim(Content) of
        <<>> -> [];
        Text -> block(escape_block_start(Text))
    end.

heading(1, Content) -> setext_heading(Content, $=);
heading(2, Content) -> setext_heading(Content, $-);
heading(Level, Content) ->
    case z_string:trim(Content) of
        <<>> -> [];
        Text -> block([lists:duplicate(Level, $#), $\s, Text])
    end.

setext_heading(Content, Character) ->
    case z_string:trim(Content) of
        <<>> -> [];
        Text ->
            Width = erlang:max(3, unicode_length(Text)),
            block([Text, $\n, lists:duplicate(Width, Character)])
    end.

wrap_inline(Marker, Content) ->
    Text = iolist_to_binary(Content),
    Trimmed = z_string:trim(Text),
    case Trimmed of
        <<>> -> Text;
        _ ->
            Leading = edge_space(Text, leading),
            Trailing = edge_space(Text, trailing),
            [Leading, Marker, Trimmed, Marker, Trailing]
    end.

edge_space(<<C/utf8, _/binary>>, leading) when C =:= $\s; C =:= $\t; C =:= $\n -> <<" ">>;
edge_space(Text, trailing) ->
    case binary:last(Text) of
        $\s -> <<" ">>;
        $\t -> <<" ">>;
        $\n -> <<" ">>;
        _ -> <<>>
    end;
edge_space(_Text, _Side) ->
    <<>>.

render_link(Attributes, Children, Context) ->
    Label = z_string:trim(render_nodes(Children, Context)),
    case proplists:get_value(<<"href">>, Attributes) of
        undefined -> Label;
        <<>> -> Label;
        Href -> render_link_1(Label, Href, proplists:get_value(<<"title">>, Attributes), Context)
    end.

render_link_1(<<>>, Href, _Title, #ctx{links = inline}) ->
    [$<, Href, $>];
render_link_1(Label, Href, _Title, #ctx{links = inline}) ->
    case link_label_matches(Label, Href) of
        true -> Label;
        false -> [Label, <<" <">>, Href, $>]
    end;
render_link_1(Label, Href, Title, #ctx{links = markdown}) ->
    case link_label_matches(Label, Href) andalso Title =:= undefined andalso safe_autolink(Href) of
        true -> [$<, Href, $>];
        false ->
            [$[, Label, <<"](">>, markdown_destination(Href), markdown_title(Title), $)]
    end.

link_label_matches(Label, <<"mailto:", Email/binary>>) -> Label =:= Email;
link_label_matches(Label, Href) -> Label =:= Href.

markdown_destination(Href) ->
    case contains_any(Href, [$\s, $\t, $(, $), $<, $>]) of
        true -> [$<, escape_angle_destination(Href), $>];
        false -> Href
    end.

escape_angle_destination(Href) ->
    EscapedOpen = binary:replace(Href, <<"<">>, <<"\\<">>, [global]),
    binary:replace(EscapedOpen, <<">">>, <<"\\>">>, [global]).

safe_autolink(Href) ->
    not contains_any(Href, [$\s, $\t, $\n, $<, $>]).

markdown_title(undefined) -> [];
markdown_title(<<>>) -> [];
markdown_title(Title) ->
    EscapedSlash = binary:replace(Title, <<"\\">>, <<"\\\\">>, [global]),
    Escaped = binary:replace(EscapedSlash, <<"\"">>, <<"\\\"">>, [global]),
    [<<" \"">>, Escaped, $"].

render_image(_Attributes, #ctx{mode = email}) ->
    [];
render_image(Attributes, #ctx{mode = Mode}) when Mode =:= default; Mode =:= faithful ->
    Src = proplists:get_value(<<"src">>, Attributes, <<>>),
    Alt = markdown_text(proplists:get_value(<<"alt">>, Attributes, <<>>)),
    Title = proplists:get_value(<<"title">>, Attributes),
    case Src of
        <<>> -> Alt;
        _ -> [$!, $[, Alt, <<"](">>, markdown_destination(Src), markdown_title(Title), $)]
    end.

render_code_span(Children) ->
    Text = z_string:trim(text_content(Children)),
    case Text of
        <<>> -> <<"``">>;
        _ ->
            Fence = binary:copy(<<"`">>, erlang:max(1, longest_run(Text, $`) + 1)),
            case binary:match(Text, <<"`">>) of
                nomatch -> [Fence, Text, Fence];
                _ -> [Fence, $\s, Text, $\s, Fence]
            end
    end.

render_code_block(Attributes, Children, _Context) ->
    {CodeChildren, CodeAttributes} = case drop_whitespace_nodes(Children) of
        [{<<"code">>, Attrs, Enclosed}] -> {Enclosed, Attrs};
        _ -> {Children, []}
    end,
    Language = code_language(Attributes, CodeAttributes),
    Text0 = code_html(CodeChildren),
    Text = trim_pre_newline(Text0),
    Fence = binary:copy(<<"`">>, erlang:max(3, longest_run(Text, $`) + 1)),
    block([Fence, Language, $\n, Text, $\n, Fence]).

code_language(PreAttributes, CodeAttributes) ->
    case proplists:get_value(<<"lang">>, PreAttributes) of
        undefined -> language_class(proplists:get_value(<<"class">>, CodeAttributes, <<>>));
        Language -> Language
    end.

language_class(Class) ->
    language_class_tokens(binary:split(Class, <<" ">>, [global])).

language_class_tokens([<<"language-", Language/binary>> | _]) -> Language;
language_class_tokens([_ | Rest]) -> language_class_tokens(Rest);
language_class_tokens([]) -> <<>>.

code_html(Nodes) ->
    Html = [code_html_node(Node) || Node <- Nodes],
    z_html:unescape(iolist_to_binary(Html)).

code_html_node(Text) when is_binary(Text) -> z_html:escape(Text);
code_html_node({comment, _Comment}) -> [];
code_html_node(Node) when is_tuple(Node) -> z_html_parse:to_html(Node).

trim_pre_newline(<<"\n", Rest/binary>>) -> trim_one_trailing_newline(Rest);
trim_pre_newline(Text) -> trim_one_trailing_newline(Text).

trim_one_trailing_newline(Text) ->
    case Text of
        <<Rest:(byte_size(Text) - 1)/binary, "\n">> when byte_size(Text) > 0 -> Rest;
        _ -> Text
    end.

quote(Content) ->
    case z_string:trim(Content) of
        <<>> -> [];
        Text -> block(prefix_lines(Text, <<"> ">>))
    end.

render_list(Type, Start, Children, Context) ->
    Items = [Item || {<<"li">>, _, _} = Item <- Children],
    {Rendered, _Next} = lists:mapfoldl(
        fun({<<"li">>, _Attributes, ItemChildren}, Index) ->
            Bullet = list_bullet(Type, Index),
            Item = render_list_item(Bullet, ItemChildren, Context),
            {Item, Index + 1}
        end,
        Start,
        Items),
    case Rendered of
        [] -> [];
        _ -> list_block(lists:join($\n, Rendered), Context)
    end.

list_block(Content, #ctx{list_depth = 0}) -> block(Content);
list_block(Content, #ctx{list_depth = _Depth}) -> [$\n, Content].

render_list_item(Bullet, Children, #ctx{list_depth = Depth} = Context) ->
    ItemContext = Context#ctx{list_depth = Depth + 1},
    Text = z_string:trim(render_nodes(Children, ItemContext)),
    Indent = binary:copy(<<" ">>, byte_size(Bullet) + 1),
    [Bullet, $\s, indent_continuation(Text, Indent)].

list_bullet(unordered, _Index) -> <<"-">>;
list_bullet(ordered, Index) -> <<(integer_to_binary(Index))/binary, $.>>.

ordered_start(Attributes) ->
    case proplists:get_value(<<"start">>, Attributes) of
        undefined -> 1;
        Value ->
            try binary_to_integer(Value) of
                Integer -> Integer
            catch
                error:badarg -> 1
            end
    end.

indent_continuation(Text, Indent) ->
    binary:replace(Text, <<"\n">>, <<"\n", Indent/binary>>, [global]).

render_markdown_table(Children, Context) ->
    {HeaderCells, BodyRows} = table_cells(Children),
    case HeaderCells of
        [] -> render_text_table(Children, Context);
        _ ->
            Header = [render_table_cell(Cell, Context) || Cell <- HeaderCells],
            Rows = [[render_table_cell(Cell, Context) || Cell <- Row] || Row <- BodyRows],
            Alignments = [cell_alignment(Cell) || Cell <- HeaderCells],
            ColumnCount = length(Header),
            NormalRows = [normalize_row(Row, ColumnCount) || Row <- Rows],
            Widths = table_widths([Header | NormalRows], Alignments),
            HeaderLine = markdown_table_row(pad_row(Header, Widths, Alignments)),
            RuleLine = markdown_table_row(table_rules(Widths, Alignments)),
            BodyLines = [markdown_table_row(pad_row(Row, Widths, Alignments)) || Row <- NormalRows],
            Caption = render_table_caption(Children, Context),
            CaptionPrefix = case Caption of
                <<>> -> [];
                _ -> [Caption, <<"\n\n">>]
            end,
            block([CaptionPrefix, HeaderLine, $\n, RuleLine, [[ $\n, Line ] || Line <- BodyLines]])
    end.

render_text_table(Children, Context) ->
    Rows = all_table_rows(Children),
    RenderedRows = [render_text_row(Row, Context) || Row <- Rows],
    Caption = render_table_caption(Children, Context),
    NonemptyRows = [Row || Row <- [Caption | RenderedRows], Row =/= <<>>],
    case NonemptyRows of
        [] -> [];
        _ -> block(lists:join($\n, NonemptyRows))
    end.

render_text_row({_Tag, _Attributes, Children}, Context) ->
    Cells = direct_cells(Children),
    Rendered = [z_string:trim(render_nodes(CellChildren, Context))
                || {_CellTag, _CellAttributes, CellChildren} <- Cells],
    Nonempty = [Cell || Cell <- Rendered, Cell =/= <<>>],
    Separator = case lists:any(fun has_newline/1, Nonempty) of
        true -> <<"\n">>;
        false -> <<" | ">>
    end,
    iolist_to_binary(lists:join(Separator, Nonempty)).

has_newline(Binary) -> binary:match(Binary, <<"\n">>) =/= nomatch.

render_table_caption(Children, Context) ->
    Captions = [z_string:trim(render_nodes(CaptionChildren, Context))
                || {<<"caption">>, _Attributes, CaptionChildren} <- Children],
    iolist_to_binary(lists:join($\n, [Caption || Caption <- Captions, Caption =/= <<>>])).

table_cells(Children) ->
    HeadRows = rows_in_section(<<"thead">>, Children),
    BodyRows = rows_in_section(<<"tbody">>, Children) ++
        rows_in_section(<<"tfoot">>, Children),
    DirectRows = [Row || {<<"tr">>, _, _} = Row <- Children],
    case {HeadRows, BodyRows ++ DirectRows} of
        {[Head | _], Rows} -> {direct_cells(element(3, Head)), [direct_cells(element(3, Row)) || Row <- Rows]};
        {[], [First | Rest]} -> {direct_cells(element(3, First)), [direct_cells(element(3, Row)) || Row <- Rest]};
        {[], []} -> {[], []}
    end.

all_table_rows(Children) ->
    DirectRows = [Row || {<<"tr">>, _, _} = Row <- Children],
    SectionRows = lists:append([
        [Row || {<<"tr">>, _, _} = Row <- SectionChildren]
        || {Section, _, SectionChildren} <- Children,
           Section =:= <<"thead">> orelse Section =:= <<"tbody">> orelse Section =:= <<"tfoot">>
    ]),
    DirectRows ++ SectionRows.

rows_in_section(Section, Children) ->
    lists:append([
        [Row || {<<"tr">>, _, _} = Row <- SectionChildren]
        || {Tag, _, SectionChildren} <- Children,
           Tag =:= Section
    ]).

direct_cells(Children) ->
    [Cell || {Tag, _, _} = Cell <- Children, Tag =:= <<"th">> orelse Tag =:= <<"td">>].

render_table_cell({_Tag, _Attributes, Children}, Context) ->
    Text0 = z_string:trim(render_nodes(Children, Context)),
    Text1 = collapse_cell_whitespace(Text0),
    escape_table_pipes(Text1, <<>>).

escape_table_pipes(<<>>, Acc) -> Acc;
escape_table_pipes(<<"\\|", Rest/binary>>, Acc) ->
    escape_table_pipes(Rest, <<Acc/binary, "\\|">>);
escape_table_pipes(<<"|", Rest/binary>>, Acc) ->
    escape_table_pipes(Rest, <<Acc/binary, "\\|">>);
escape_table_pipes(<<C/utf8, Rest/binary>>, Acc) ->
    escape_table_pipes(Rest, <<Acc/binary, C/utf8>>).

collapse_cell_whitespace(Text) ->
    re:replace(Text, <<"[\\s\\r\\n]+">>, <<" ">>, [global, unicode, {return, binary}]).

cell_alignment({_Tag, Attributes, _Children}) ->
    case proplists:get_value(<<"align">>, Attributes) of
        <<"left">> -> left;
        <<"right">> -> right;
        <<"center">> -> center;
        _ -> none
    end.

normalize_row(Row, ColumnCount) when length(Row) < ColumnCount ->
    Row ++ lists:duplicate(ColumnCount - length(Row), <<>>);
normalize_row(Row, ColumnCount) ->
    lists:sublist(Row, ColumnCount).

table_widths(Rows, Alignments) ->
    Minimums = [alignment_minimum(Alignment) || Alignment <- Alignments],
    lists:foldl(fun row_widths/2, Minimums, Rows).

row_widths(Row, Widths) ->
    [erlang:min(?MAX_TABLE_CELL_WIDTH, erlang:max(Width, unicode_length(Cell)))
     || {Cell, Width} <- lists:zip(normalize_row(Row, length(Widths)), Widths)].

alignment_minimum(center) -> 5;
alignment_minimum(_Alignment) -> 4.

pad_row(Row, Widths, Alignments) ->
    [pad_cell(Cell, Width, Alignment)
     || {Cell, {Width, Alignment}} <- lists:zip(Row, lists:zip(Widths, Alignments))].

pad_cell(Cell, Width, right) ->
    pad_left(Cell, Width);
pad_cell(Cell, Width, center) ->
    Length = unicode_length(Cell),
    Left = erlang:max(0, (Width - Length) div 2),
    Right = erlang:max(0, Width - Length - Left),
    [spaces(Left), Cell, spaces(Right)];
pad_cell(Cell, Width, _Alignment) ->
    [Cell, spaces(erlang:max(0, Width - unicode_length(Cell)))].

pad_left(Cell, Width) ->
    [spaces(erlang:max(0, Width - unicode_length(Cell))), Cell].

table_rules(Widths, Alignments) ->
    [table_rule(Width, Alignment) || {Width, Alignment} <- lists:zip(Widths, Alignments)].

table_rule(Width, left) -> [$:, dashes(Width - 1)];
table_rule(Width, right) -> [dashes(Width - 1), $:];
table_rule(Width, center) -> [$:, dashes(Width - 2), $:];
table_rule(Width, none) -> dashes(Width).

markdown_table_row(Cells) ->
    iolist_to_binary([<<"| ">>, lists:join(<<" | ">>, Cells), <<" |">>]).

spaces(Count) -> binary:copy(<<" ">>, Count).
dashes(Count) -> binary:copy(<<"-">>, Count).

table_is_representable({<<"table">>, _Attributes, Children}) ->
    Rows = all_table_rows(Children),
    Rows =/= [] andalso
        length(rows_in_section(<<"thead">>, Children)) =< 1 andalso
        lists:all(fun row_is_representable/1, Rows) andalso
        table_sections_only(Children).

table_sections_only(Children) ->
    lists:all(
        fun
            (Text) when is_binary(Text) -> z_string:trim(Text) =:= <<>>;
            ({Tag, Attributes, _}) when Tag =:= <<"thead">>;
                                             Tag =:= <<"tbody">>;
                                             Tag =:= <<"tfoot">> -> Attributes =:= [];
            ({<<"tr">>, _, _}) -> true;
            (_) -> false
        end,
        Children).

row_is_representable({<<"tr">>, Attributes, Children}) ->
    Attributes =:= [] andalso
        direct_cells(Children) =/= [] andalso
        lists:all(
            fun
                (Text) when is_binary(Text) -> z_string:trim(Text) =:= <<>>;
                ({Tag, CellAttributes, _}) when Tag =:= <<"th">>; Tag =:= <<"td">> ->
                    only_attributes(CellAttributes, [<<"align">>]) andalso
                        valid_alignment(CellAttributes);
                (_) -> false
            end,
            Children).

valid_alignment(Attributes) ->
    case proplists:get_value(<<"align">>, Attributes) of
        undefined -> true;
        <<"left">> -> true;
        <<"right">> -> true;
        <<"center">> -> true;
        _ -> false
    end.

is_checkbox(Attributes) ->
    proplists:get_value(<<"type">>, Attributes) =:= <<"checkbox">>.

supported_pre_class(undefined) -> true;
supported_pre_class(<<"notranslate">>) -> true;
supported_pre_class(_) -> false.

pre_is_representable(Children) ->
    case drop_whitespace_nodes(Children) of
        [{<<"code">>, Attributes, _CodeChildren}] -> supported_code_block_attributes(Attributes);
        Nodes -> lists:all(fun is_pre_text_node/1, Nodes)
    end.

supported_code_block_attributes(Attributes) ->
    only_attributes(Attributes, [<<"class">>]) andalso
        case proplists:get_value(<<"class">>, Attributes) of
            undefined -> true;
            Classes -> lists:all(fun supported_code_class/1, class_tokens(Classes))
        end.

supported_code_class(<<"notranslate">>) -> true;
supported_code_class(<<"language-", Language/binary>>) -> Language =/= <<>>;
supported_code_class(_) -> false.

class_tokens(Classes) ->
    [Token || Token <- binary:split(Classes, <<" ">>, [global]), Token =/= <<>>].

is_pre_text_node(Text) when is_binary(Text) -> true;
is_pre_text_node({comment, _Comment}) -> true;
is_pre_text_node(_Node) -> false.

is_hidden(_Node, #ctx{mode = faithful}) ->
    false;
is_hidden({_Tag, Attributes, _Children}, #ctx{mode = default}) ->
    is_aria_hidden(Attributes);
is_hidden({_Tag, Attributes, _Children}, #ctx{mode = email}) ->
    proplists:is_defined(<<"hidden">>, Attributes)
        orelse is_aria_hidden(Attributes)
        orelse hidden_style(proplists:get_value(<<"style">>, Attributes, <<>>)).

is_aria_hidden(Attributes) ->
    case proplists:get_value(<<"aria-hidden">>, Attributes) of
        Value when is_binary(Value) -> string:lowercase(Value) =:= <<"true">>;
        _ -> false
    end.

is_presentation_table(<<"table">>, Attributes, #ctx{mode = default}) ->
    is_presentation_role(Attributes);
is_presentation_table(_Tag, _Attributes, _Context) ->
    false.

is_presentation_role(Attributes) ->
    case proplists:get_value(<<"role">>, Attributes) of
        Value when is_binary(Value) -> string:lowercase(Value) =:= <<"presentation">>;
        _ -> false
    end.

hidden_style(Style) ->
    Compact = re:replace(string:lowercase(Style), <<"\\s+">>, <<>>, [global, unicode, {return, binary}]),
    contains_any_binary(Compact, [<<"display:none">>, <<"visibility:hidden">>, <<"mso-hide:all">>]).

raw_html(Node, Tag) ->
    Html = z_html_parse:to_html(Node),
    case is_block_tag(Tag) of
        true -> block(Html);
        false -> Html
    end.

block(Content) ->
    [$\n, Content, $\n].

prefix_lines(Text, Prefix) ->
    [Prefix, binary:replace(Text, <<"\n">>, <<"\n", Prefix/binary>>, [global])].

collapse_whitespace(Text) ->
    collapse_whitespace(Text, false, <<>>).

collapse_whitespace(<<>>, true, Acc) -> <<Acc/binary, $\s>>;
collapse_whitespace(<<>>, false, Acc) -> Acc;
collapse_whitespace(<<C, Rest/binary>>, _InWhitespace, Acc)
        when C =:= $\s; C =:= $\t; C =:= $\r; C =:= $\n; C =:= $\f ->
    collapse_whitespace(Rest, true, Acc);
collapse_whitespace(<<C/utf8, Rest/binary>>, true, Acc) ->
    collapse_whitespace(Rest, false, <<Acc/binary, $\s, C/utf8>>);
collapse_whitespace(<<C/utf8, Rest/binary>>, false, Acc) ->
    collapse_whitespace(Rest, false, <<Acc/binary, C/utf8>>).

markdown_text(Text) ->
    markdown_text(Text, <<>>).

markdown_text(<<>>, Acc) -> Acc;
markdown_text(<<C, Rest/binary>>, Acc) when
        C =:= $\\; C =:= $`; C =:= $*; C =:= $_;
        C =:= ${; C =:= $}; C =:= $[; C =:= $];
        C =:= $|; C =:= $~; C =:= $^ ->
    markdown_text(Rest, <<Acc/binary, $\\, C>>);
markdown_text(<<$&, Rest/binary>>, Acc) ->
    case maybe_entity(Rest) of
        true -> markdown_text(Rest, <<Acc/binary, "&amp;">>);
        false -> markdown_text(Rest, <<Acc/binary, $&>>)
    end;
markdown_text(<<$<, Rest/binary>>, Acc) ->
    case maybe_tag_or_autolink(Rest) of
        true -> markdown_text(Rest, <<Acc/binary, "&lt;">>);
        false -> markdown_text(Rest, <<Acc/binary, $<>>)
    end;
markdown_text(<<C/utf8, Rest/binary>>, Acc) ->
    markdown_text(Rest, <<Acc/binary, C/utf8>>).

maybe_entity(<<$#, _/binary>>) -> true;
maybe_entity(<<C, Rest/binary>>) when C >= $a, C =< $z -> maybe_named_entity(Rest);
maybe_entity(<<C, Rest/binary>>) when C >= $A, C =< $Z -> maybe_named_entity(Rest);
maybe_entity(_) -> false.

maybe_named_entity(<<$;, _/binary>>) -> true;
maybe_named_entity(<<C, Rest/binary>>) when C >= $a, C =< $z -> maybe_named_entity(Rest);
maybe_named_entity(<<C, Rest/binary>>) when C >= $A, C =< $Z -> maybe_named_entity(Rest);
maybe_named_entity(<<C, Rest/binary>>) when C >= $0, C =< $9 -> maybe_named_entity(Rest);
maybe_named_entity(_) -> false.

maybe_tag_or_autolink(<<C, Rest/binary>>) when C >= $a, C =< $z ->
    binary:match(Rest, <<">">>) =/= nomatch;
maybe_tag_or_autolink(<<C, Rest/binary>>) when C >= $A, C =< $Z ->
    binary:match(Rest, <<">">>) =/= nomatch;
maybe_tag_or_autolink(<<"/", _/binary>>) -> true;
maybe_tag_or_autolink(_) -> false.

escape_block_start(<<"#", Rest/binary>>) -> <<"\\#", Rest/binary>>;
escape_block_start(<<">", Rest/binary>>) -> <<"\\>", Rest/binary>>;
escape_block_start(<<"- ", Rest/binary>>) -> <<"\\- ", Rest/binary>>;
escape_block_start(<<"+ ", Rest/binary>>) -> <<"\\+ ", Rest/binary>>;
escape_block_start(Text) -> escape_ordered_start(Text, Text, <<>>).

escape_ordered_start(<<C, Rest/binary>>, Original, Digits) when C >= $0, C =< $9 ->
    escape_ordered_start(Rest, Original, <<Digits/binary, C>>);
escape_ordered_start(<<". ", Rest/binary>>, _Original, Digits) when Digits =/= <<>> ->
    <<Digits/binary, "\\. ", Rest/binary>>;
escape_ordered_start(_Rest, Original, _Digits) -> Original.

text_content(Nodes) when is_list(Nodes) ->
    iolist_to_binary([text_content(Node) || Node <- Nodes]);
text_content(Text) when is_binary(Text) -> Text;
text_content({comment, _Comment}) -> [];
text_content({_Tag, _Attributes, Children}) -> text_content(Children);
text_content(_Node) -> [].

drop_whitespace_nodes(Nodes) ->
    [Node || Node <- Nodes, not is_whitespace_node(Node)].

is_whitespace_node(Text) when is_binary(Text) -> z_string:trim(Text) =:= <<>>;
is_whitespace_node(_Node) -> false.

is_block_tag(Tag) ->
    lists:member(Tag, [
        <<"address">>, <<"article">>, <<"aside">>, <<"blockquote">>,
        <<"details">>, <<"div">>, <<"dl">>, <<"fieldset">>, <<"figcaption">>,
        <<"figure">>, <<"footer">>, <<"form">>, <<"h1">>, <<"h2">>, <<"h3">>,
        <<"h4">>, <<"h5">>, <<"h6">>, <<"head">>, <<"header">>, <<"hr">>,
        <<"html">>, <<"main">>, <<"nav">>, <<"ol">>, <<"p">>, <<"pre">>,
        <<"script">>, <<"section">>, <<"style">>, <<"table">>, <<"template">>,
        <<"ul">>
    ]).

contains_any(Binary, Characters) ->
    lists:any(fun(Character) -> binary:match(Binary, <<Character>>) =/= nomatch end, Characters).

contains_any_binary(Binary, Needles) ->
    lists:any(fun(Needle) -> binary:match(Binary, Needle) =/= nomatch end, Needles).

unicode_length(Binary) ->
    string:length(unicode:characters_to_list(Binary)).

longest_run(Binary, Character) ->
    longest_run(Binary, Character, 0, 0).

longest_run(<<Character, Rest/binary>>, Character, Current, Longest) ->
    Next = Current + 1,
    longest_run(Rest, Character, Next, erlang:max(Next, Longest));
longest_run(<<_Byte, Rest/binary>>, Character, _Current, Longest) ->
    longest_run(Rest, Character, 0, Longest);
longest_run(<<>>, _Character, _Current, Longest) ->
    Longest.
