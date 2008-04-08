-module(bjc_config).
-author("bjc@kublai.com").

-export([start/0, load_file/1, get_hosts/0, get_option/2]).
-include_lib("stdlib/include/qlc.hrl").
-include("ejabberd.hrl").

-define(TABLE_PREFIX, "config_").
-record(configuration, {key, value}).
-record(hosts, {name, config, overrides}).
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
    ok = create_tables(Terms),
    {atomic, ok} = mnesia:transaction(fun () -> process_terms(Terms, default) end).

get_hosts() ->
    Fun = fun () ->
                  Q = qlc:q([H#hosts.name || H <- mnesia:table(hosts)]),
                  qlc:e(Q)
          end,
    {atomic, Res} = mnesia:transaction(Fun),
    Res.

get_option(all, Name) ->
    Fun = fun () ->
                  Q = qlc:q([Host#hosts.config || Host <- mnesia:table(hosts)]),
                  Tabs = sets:from_list(qlc:e(Q)),
                  sets:fold(fun (Table, Accum) ->
                                    case mnesia:read({Table, Name}) of
                                        [#configuration{key = Name, value = Val}] -> [Val | Accum];
                                        _ -> Accum
                                    end
                            end, [], Tabs)
          end,
    {atomic, Res} = mnesia:transaction(Fun),
    Res;
get_option(Table, Name) when is_atom(Table) ->
    Fun = fun () ->
                  [#configuration{key = Name, value = Val}] = mnesia:read({Table, Name}),
                  Val
          end,
    case mnesia:transaction(Fun) of
        {atomic, Res} -> Res;
        _ -> undefined
    end;

get_option(Host, Name) when is_list(Host) ->
    Fun = fun () ->
                  [#hosts{config = Table}] = mnesia:read({hosts, Host}),
                  get_option(Table, Name)
          end,
    case mnesia:transaction(Fun) of
        {atomic, Res} -> Res;
        _ -> undefined
    end.

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
    mnesia:create_table(hosts, [{ram_copies, [node()]}, {attributes, record_info(fields, hosts)}]),
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
    mnesia:write(Table, #configuration{key = {acl, Name}, value = Val}, write),
    {ok, Table};
process_term({access, Name, Val}, {ok, Table}) ->
    mnesia:write(Table, #configuration{key = {access, Name}, value = Val}, write),
    {ok, Table};
process_term({shaper, Name, Val}, {ok, Table}) ->
    mnesia:write(Table, #configuration{key = {shaper, Name}, value = Val}, write),
    {ok, Table};
process_term({hosts, Hosts}, {ok, Table}) ->
    {process_hosts(Hosts), Table};
process_term({Key, Val}, {ok, Table}) ->
    mnesia:write(Table, #configuration{key = Key, value = Val}, write),
    {ok, Table};
process_term(Term, {ok, _Table}) ->
    {bad_term, Term};
process_term(_Term, LastResult) ->
    LastResult.

process_hosts(HostTerms) ->
    NormHosts = [normalize_host_term(Term) || Term <- HostTerms],
    lists:foreach(fun (Record) -> mnesia:write(Record) end, NormHosts),
    ok.

normalize_host_term({Name, Config, Overrides}) ->
    #hosts{name = Name, config = name_for_table(Config), overrides = Overrides};
normalize_host_term({Name, Config}) ->
    normalize_host_term({Name, Config, []});
normalize_host_term(Name) ->
    normalize_host_term({Name, default, []}).

name_for_table(Table) ->
    list_to_atom(?TABLE_PREFIX ++ atom_to_list(Table)).
    
