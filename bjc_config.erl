-module(bjc_config).
-author("bjc@kublai.com").

-compile(export_all).
%-export([start/0, load_file/1]).
-include("ejabberd.hrl").

-record(load_info, {includes = sets:new(), terms = [], cwd}).

start() ->
    Config = case application:get_env(config) of
		 {ok, Path} -> Path;
		 undefined -> 
		     case os:getenv("EJABBERD_CONFIG_PATH") of
			 false ->
			     ?CONFIG_PATH;
			 Path ->
			     Path
		     end
	     end,
    load_file(Config).

load_file(Filename) ->
    {ok, Terms} = preprocess(Filename),
    ok = process_terms(Terms, default).

preprocess(Filename) ->
    Filename2 = filename:absname(Filename),
    Cwd = filename:dirname(Filename2),
    LoadInfo = preprocess(Filename2, #load_info{includes = sets:from_list([Filename2]), cwd = Cwd}),
    {ok, LoadInfo#load_info.terms}.

preprocess(Filename, #load_info{includes = Included, terms = Others, cwd = Cwd}) ->
    case file:consult(Filename) of
        {error, Reason} ->
            ?ERROR_MSG("Couldn't load ~p: ~p", [Filename, Reason]),
            exit({error, unable_to_load, Filename, Reason});

        {ok, Terms} ->
            IncludeInfo = lists:foldl(fun find_includes/2,
                                      #load_info{includes = Included, cwd = Cwd},
                                      Terms),
            IncludeInfo2 = sets:fold(fun preprocess/2,
                                     #load_info{includes = IncludeInfo#load_info.includes, cwd = Cwd},
                                     sets:subtract(IncludeInfo#load_info.includes, Included)),
            #load_info{includes = IncludeInfo2#load_info.includes,
                       terms = Others ++ IncludeInfo2#load_info.terms ++ lists:reverse(IncludeInfo#load_info.terms),
                       cwd = Cwd}
    end.

find_includes([], #load_info{} = Accum) ->
    Accum;
find_includes({include, Filename}, #load_info{includes = Includes, cwd = Cwd} = Accum) ->
    Truename = filename:absname_join(Cwd, Filename),
    Accum#load_info{includes = sets:add_element(Truename, Includes)};
find_includes(Term, #load_info{terms = Other} = Accum) ->
    Accum#load_info{terms = [Term | Other]}.

process_terms(Terms, Table) ->
    {ok, _} = lists:foldl(fun process_terms2/2, {ok, Table}, Terms),
    ok.

process_terms2({configuration, Name, Terms}, {ok, Table}) ->
    ok = process_terms(Terms, Name),
    {ok, Table};
process_terms2(Term, {ok, Table}) ->
    io:format("DEBUG: ~p -> ~p~n", [Term, Table]),
    {ok, Table};
process_terms2(_Term, _LastResult) ->
    _LastResult.
