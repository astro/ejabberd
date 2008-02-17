-module(odbc_pool).
-behavior(supervisor).

-define(DEFAULT_DB_PORT, 3306).
-define(DEFAULT_POOL_SIZE, 5).

-export([start_link/0, sql_query/1, sql_transaction/1]).
-export([init/1]).

start_link() ->
    case ejabberd_config:get_local_option(odbc_server) of
        {mysql, DBHost, DBName, DBUser, DBPass} ->
            DBPort = ?DEFAULT_DB_PORT;
        {mysql, DBHost, DBPort, DBName, DBUser, DBPass} ->
            ok
    end,
    PoolSize = case ejabberd_config:get_local_option(odbc_pool_size) of
                   undefined -> ?DEFAULT_POOL_SIZE;
                   N -> N
               end,
    supervisor:start_link({local, ?MODULE}, ?MODULE, [PoolSize, {DBHost, DBPort, DBName, DBUser, DBPass}]).

%% Use a random connection from the pool to answer Query.
sql_query(Query) ->
    gen_server:call(random_conn(), {sql_query, Query}).

%% Use a random connection from the pool to issue the
%% transaction. Transaction may be a list of queries or a single
%% function of one argument (the DBRef queries are issued on).
sql_transaction(Queries) when is_list(Queries) ->
    F = fun (Ref) ->
                lists:foreach(fun (Query) -> odbc_connection:sql_query_t(Ref, Query) end,
                              Queries)
        end,
    sql_transaction(F);
sql_transaction(F) ->
    gen_server:call(random_conn(), {sql_transaction, F}).

init([Count, {DBHost, DBPort, DBName, DBUser, DBPass}]) ->
    {ok, {{one_for_one, 10, 1},
          lists:map(fun (I) ->
                            Name = list_to_atom(atom_to_list(?MODULE) ++ "_" ++ integer_to_list(I)),
                            {Name, {odbc_connection, start_link, [DBHost, DBPort, DBName, DBUser, DBPass]},
                             permanent, brutal_kill, worker, [?MODULE]}
                    end,
                    lists:seq(1, Count))}}.

random_conn() ->
    Pids = get_pids(),
    lists:nth(erlang:phash(now(), length(Pids)), Pids).

get_pids() ->
    [Pid || {_Id, Pid, _Type, _Modules} <- supervisor:which_children(?MODULE)].
