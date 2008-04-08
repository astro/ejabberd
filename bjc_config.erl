%% TODO - handle domain_certfile config option. The biggest problem
%% here is that we don't want to create one config per-domain, but
%% domains are keyed one:one with configs.

%% NFC how to handle this w/o a hack.

%% Also, we're ending up w/ hosts inside config_default, which is not
%% what we want. It should be a separate table entirely.

-module(bjc_config).
-author("bjc@kublai.com").

-export([start/0, load_file/1]).
-include("ejabberd.hrl").

-define(TABLE_PREFIX, "config_").
-record(configuration, {key, value}).
-record(load_info, {includes = sets:new(), terms = [], cwd}).

start() ->
    ok = debug_start(),
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
    ok = create_tables(Terms),
    {atomic, ok} = mnesia:transaction(fun () -> process_terms(Terms, default) end).

debug_start() ->
    application:start(mnesia),
    os:putenv("EJABBERD_CONFIG_PATH", "/Users/bjc/src/ejabberd-bjc/test/ejabberd.cfg"),
    ok.

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

create_tables(Terms) ->
    Tables = [default | lists:foldl(fun ({configuration, Table, _Terms}, Accum) ->
                                            [Table | Accum];
                                        (_, Accum) -> Accum
                                    end, [], Terms)],
    CreateFun = fun (Table) ->
                        mnesia:create_table(name_for_table(Table),
                                            [{ram_copies, [node()]},
                                             {attributes, record_info(fields, configuration)},
                                             {record_name, configuration}])
                end,
    lists:foreach(CreateFun, Tables),
    ok.

process_terms(Terms, Table) ->
    {ok, _} = lists:foldl(fun process_term/2, {ok, name_for_table(Table)}, Terms),
    ok.

process_term({configuration, Name, Terms}, {ok, Table}) ->
    ok = process_terms(Terms, Name),
    {ok, Table};
process_term({acl, Name, Val}, {ok, Table}) ->
    mnesia:write(Table, #configuration{key = acl, value = {Name, Val}}, write),
    {ok, Table};
process_term({access, Name, Val}, {ok, Table}) ->
    mnesia:write(Table, #configuration{key = access, value = {Name, Val}}, write),
    {ok, Table};
process_term({shaper, Name, Val}, {ok, Table}) ->
    mnesia:write(Table, #configuration{key = shaper, value = {Name, Val}}, write),
    {ok, Table};
process_term({Key, Val}, {ok, Table}) ->
    mnesia:write(Table, #configuration{key = Key, value = Val}, write),
    {ok, Table};
process_term(Term, {ok, _Table}) ->
    {bad_term, Term};
process_term(_Term, LastResult) ->
    LastResult.

name_for_table(Table) ->
    list_to_atom(?TABLE_PREFIX ++ atom_to_list(Table)).
    
