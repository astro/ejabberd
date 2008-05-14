-module(mod_filestore_service).
-author('astro@spaceboyz.net').

-behaviour(gen_server).

%% gen_server callbacks.
-export([init/1,
	 handle_info/2,
	 handle_call/3,
	 handle_cast/2,
	 terminate/2,
	 code_change/3
	]).

%% API.
-export([start_link/2]).

-include("ejabberd.hrl").
-include("jlib.hrl").

-define(PROCNAME, ejabberd_mod_filestore_service).

-record(state, {
	  myhost,
	  nodes % {Node, Pid}
	 }).

%% Unused callbacks.
handle_cast(_Request, State) ->
    {noreply, State}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
handle_call(_Request, _From, State) ->
    {reply, ok, State}.
%%----------------

start_link(Host, Opts) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    gen_server:start_link({local, Proc}, ?MODULE, [Host, Opts], []).

init([Host, Opts]) ->
    MyHost = gen_mod:get_opt_host(Host, Opts, "filestore.@HOST@"),
    ?DEBUG("Registering route for ~p",[MyHost]),
    ejabberd_router:register_route(MyHost),
    Nodes = [mod_filestore_node:start_link("public", MyHost, [public]),
	     mod_filestore_node:start_link("private", MyHost, [private])],
    {ok, #state{myhost = MyHost, nodes = Nodes}}.

terminate(_Reason, #state{myhost = MyHost}) ->
    ejabberd_router:unregister_route(MyHost),
    ok.

handle_info({route, From, To, Packet}=Info, State=#state{nodes = Nodes}) ->
    case node_pid(To#jid.user, Nodes) of
	not_found ->
	    Err = jlib:make_error_reply(Packet, ?ERR_ITEM_NOT_FOUND),
	    ejabberd_router:route(To, From, Err);
	Pid ->
	    gen_server:cast(Pid, Info)
    end,
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

%% Internal functions

node_pid(Node, [{Node, Pid} | _]) ->
    Pid;
node_pid(Node, [_ | Nodes]) ->
    node_pid(Node, Nodes);
node_pid(_, []) ->
    not_found.
