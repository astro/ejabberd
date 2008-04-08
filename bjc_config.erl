-module(bjc_config).
-author("bjc@kublai.com").

-compile(export_all).
-include("ejabberd.hrl").

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
    load_file(Filename, {sets:new(), []}).

load_file(Filename, {Included, Others}) ->
    case file:consult(Filename) of
        {error, Reason} ->
            ?ERROR_MSG("Couldn't load ~p: ~p", [Filename, Reason]),
            exit({error, unable_to_load, Filename, Reason});

        {ok, Terms} ->
            {Includes, Others2} = lists:foldl(fun find_includes/2, {Included, []}, Terms),
            {Includes2, IncludeOthers} = sets:fold(fun load_file/2, {Includes, []},
                                                   sets:subtract(Includes, Included)),
            {Includes2, Others ++ IncludeOthers ++ Others2}
    end.

find_includes([], Accum) ->
    Accum;
find_includes({include, Filename}, {Includes, Other}) ->
    Truename = truename(Filename),
    {sets:add_element(Truename, Includes), Other};
find_includes(Term, {Includes, Other}) ->
    {Includes, [Term | Other]}.

%% Convert relative or absolute path into a normalized path from root.
truename(Filename) ->
    Filename.
