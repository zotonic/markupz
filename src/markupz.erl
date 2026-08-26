%% Copyright 2026 Marc Worrell
%% SPDX-License-Identifier: Apache-2.0
%% @doc Convert HTML fragments to Markdown or readable email text.
-module(markupz).

-export([
    convert/1,
    convert/2,
    to_markdown/1,
    to_markdown/2,
    to_email_text/1
]).

-type mode() :: default | faithful | email.
-type html_option() :: keep | strip.
-type table_option() :: markdown | text.
-type link_option() :: markdown | inline.
-type options() :: #{
    mode => mode(),
    html => html_option(),
    tables => table_option(),
    links => link_option()
}.
-type option_input() :: mode() | options().
-type reason() :: invalid_unicode | {invalid_option, atom(), term()} | term().

-export_type([mode/0, options/0, reason/0]).

%% @doc Convert HTML using the default preset.
%%
%% Raises `error({invalid_html, Reason})' if the input or options are invalid.
-spec to_markdown(iodata()) -> binary().
to_markdown(Html) ->
    to_markdown(Html, default).

%% @doc Convert HTML using a preset or an option map.
%%
%% The `default' preset converts body content, omits ARIA-hidden elements, and
%% flattens presentation tables. The `faithful' preset also includes document
%% metadata and presentation HTML. The `email' preset strips unsupported HTML,
%% removes hidden email content, and writes link destinations inline.
-spec to_markdown(iodata(), option_input()) -> binary().
to_markdown(Html, Options) ->
    case convert(Html, Options) of
        {ok, Markdown} -> Markdown;
        {error, Reason} -> error({invalid_html, Reason})
    end.

%% @doc Convert an HTML email body to a readable text alternative.
-spec to_email_text(iodata()) -> binary().
to_email_text(Html) ->
    to_markdown(Html, email).

%% @doc Safely convert HTML using the default preset.
-spec convert(iodata()) -> {ok, binary()} | {error, reason()}.
convert(Html) ->
    convert(Html, default).

%% @doc Safely convert HTML using a preset or option map.
-spec convert(iodata(), option_input()) -> {ok, binary()} | {error, reason()}.
convert(Html, Options0) ->
    case normalize_options(Options0) of
        {ok, Options} ->
            convert_html(Html, Options);
        {error, _} = Error ->
            Error
    end.

convert_html(Html, Options) ->
    case unicode:characters_to_binary(Html) of
        HtmlBin when is_binary(HtmlBin) ->
            parse_fragment(HtmlBin, Options);
        {error, _Encoded, _Rest} ->
            {error, invalid_unicode};
        {incomplete, _Encoded, _Rest} ->
            {error, invalid_unicode}
    end.

parse_fragment(Html, Options) ->
    Root = unused_root_tag(string:lowercase(Html), 0),
    Wrapped = [<<"<">>, Root, <<">">>, Html, <<"</">>, Root, <<">">>],
    case z_html_parse:parse(Wrapped) of
        {ok, {Root, _Attributes, Children}} ->
            Content = select_content(Children, maps:get(mode, Options)),
            {ok, markupz_renderer:render(Content, Options)};
        {ok, Other} ->
            {error, {unexpected_tree, Other}};
        {error, _} = Error ->
            Error
    end.

select_content(Children, default) ->
    case find_body(Children) of
        {ok, Attributes, BodyChildren} ->
            case is_aria_hidden(Attributes) of
                true -> [];
                false -> BodyChildren
            end;
        error ->
            Children
    end;
select_content(Children, _Mode) ->
    Children.

find_body([{<<"body">>, Attributes, Children} | _Rest]) ->
    {ok, Attributes, Children};
find_body([{<<"html">>, _Attributes, Children} | Rest]) ->
    case find_body(Children) of
        error -> find_body(Rest);
        {ok, _, _} = Body -> Body
    end;
find_body([_Node | Rest]) ->
    find_body(Rest);
find_body([]) ->
    error.

is_aria_hidden(Attributes) ->
    case proplists:get_value(<<"aria-hidden">>, Attributes) of
        Value when is_binary(Value) -> string:lowercase(Value) =:= <<"true">>;
        _ -> false
    end.

unused_root_tag(Html, N) ->
    Tag = iolist_to_binary([<<"markupz-fragment-">>, integer_to_binary(N)]),
    case binary:match(Html, Tag) of
        nomatch -> Tag;
        _ -> unused_root_tag(Html, N + 1)
    end.

normalize_options(default) ->
    {ok, defaults(default)};
normalize_options(faithful) ->
    {ok, defaults(faithful)};
normalize_options(email) ->
    {ok, defaults(email)};
normalize_options(Options) when is_map(Options) ->
    Mode = maps:get(mode, Options, default),
    case Mode of
        default -> validate_options(maps:merge(defaults(default), Options));
        faithful -> validate_options(maps:merge(defaults(faithful), Options));
        email -> validate_options(maps:merge(defaults(email), Options));
        _ -> {error, {invalid_option, mode, Mode}}
    end;
normalize_options(Mode) when is_atom(Mode) ->
    {error, {invalid_option, mode, Mode}};
normalize_options(Options) ->
    {error, {invalid_option, options, Options}}.

defaults(default) ->
    #{
        mode => default,
        html => keep,
        tables => markdown,
        links => markdown
    };
defaults(faithful) ->
    #{
        mode => faithful,
        html => keep,
        tables => markdown,
        links => markdown
    };
defaults(email) ->
    #{
        mode => email,
        html => strip,
        tables => text,
        links => inline
    }.

validate_options(#{html := Html}) when Html =/= keep, Html =/= strip ->
    {error, {invalid_option, html, Html}};
validate_options(#{tables := Tables})
        when Tables =/= markdown, Tables =/= text ->
    {error, {invalid_option, tables, Tables}};
validate_options(#{links := Links}) when Links =/= markdown, Links =/= inline ->
    {error, {invalid_option, links, Links}};
validate_options(Options) ->
    {ok, Options}.
