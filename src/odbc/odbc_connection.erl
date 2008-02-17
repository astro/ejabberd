-module(odbc_connection).
-behavior(gen_server).

-define(MAX_TRANSACTION_RESTARTS, 10).
-define(KEEPALIVE_QUERY, "SELECT 1;").

-export([start_link/5]).
-export([init/1, terminate/2, handle_call/3, handle_cast/2,
         handle_info/2, code_change/3]).
-export([keep_alive/1]).

 % XXX: This shouldn't be exposed. But the cost is high. sql_query
 % should be transactional, and we should expose "dirty" commands,
 % upon which the transactional is built. Doing it the other way is
 % wrong, as it inverts the relation in SQL syntax.
-export([sql_query_t/2]).

start_link(DBHost, DBPort, DBName, DBUser, DBPassword) ->
    gen_server:start_link(?MODULE,
                          [DBHost, DBPort, DBName, DBUser, DBPassword],
                          []).

keep_alive(PID) ->
    gen_server:call(PID, {sql_query, ?KEEPALIVE_QUERY}, 60000).

%% Start up the link to MySQL.
init([DBHost, DBPort, DBName, DBUser, DBPassword]) ->
    case ejabberd_config:get_local_option(odbc_keepalive_interval) of
        undefined -> ok;
        T -> timer:apply_interval(T * 1000, ?MODULE, keep_alive, [self()])
    end,
    Logger = fun(_Level, _Format, _Argument) -> ok end,
    {ok, Ref} = mysql_conn:start(DBHost, DBPort, DBUser, DBPassword, DBName, Logger),
    erlang:monitor(process, Ref),
    mysql_conn:fetch(Ref, ["set names 'utf8';"], self()),
    {ok, Ref}.

terminate(_Reason, _State) ->
    ok.

handle_call({sql_query, Query}, _From, State) ->
    {reply, sql_query(State, Query), State};
handle_call({sql_transaction, F}, _From, State) ->
    {reply, sql_transaction(State, F), State};
handle_call(Msg, _From, State) ->
    {reply, {invalid_message, Msg}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

% Answer Query on Ref.
sql_query(Ref, Query) ->
    mysql_to_odbc(mysql_conn:fetch(Ref, Query, self())).

% Answer Query inside transaction on Ref.
sql_query_t(Ref, Query) ->
    Res = sql_query(Ref, Query),
    case Res of
        {error, "No SQL-driver information available."} ->
	    % workaround for odbc bug
            {updated, 0};
        {error, _} ->
            throw(aborted);
        Rs when is_list(Rs) ->
            case lists:keymember(error, 1, Rs) of
                true ->
                    throw(aborted);
                _ ->
                    Res
            end;
        _ ->
            Res
    end.

% Satisfy transaction on Ref.
sql_transaction(Ref, F) ->
    sql_transaction(Ref, F, ?MAX_TRANSACTION_RESTARTS).

sql_transaction(_Ref, _F, 0) ->
    {aborted, restarts_exceeded};
sql_transaction(Ref, F, Restarts) ->
    sql_query(Ref, "BEGIN"),
    case catch F(Ref) of
        aborted ->
            sql_transaction(Ref, F, Restarts - 1);
        {'EXIT', Reason} ->
            sql_query(Ref, "ROLLBACK"),
            {aborted, Reason};
        Res ->
            sql_query(Ref, "COMMIT"),
            {atomic, Res}
    end.

%% Convert MySQL query result to Erlang ODBC result formalism
mysql_to_odbc({updated, MySQLRes}) ->
    {updated, mysql:get_result_affected_rows(MySQLRes)};
mysql_to_odbc({data, MySQLRes}) ->
    mysql_item_to_odbc(mysql:get_result_field_info(MySQLRes),
		       mysql:get_result_rows(MySQLRes));
mysql_to_odbc({error, MySQLRes}) ->
    {error, mysql:get_result_reason(MySQLRes)}.

%% When tabular data is returned, convert it to the ODBC formalism
mysql_item_to_odbc(Columns, Recs) ->
    %% For now, there is a bug and we do not get the correct value from MySQL
    %% module:
    {selected,
     [element(2, Column) || Column <- Columns],
     [list_to_tuple(Rec) || Rec <- Recs]}.
