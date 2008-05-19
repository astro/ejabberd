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
-export([start_link/2, get_streamhosts/1, get_streamhost/2]).

-include("ejabberd.hrl").
-include("jlib.hrl").

-define(PROCNAME, ejabberd_mod_filestore_service).

-record(state, {
	  myhost,
	  nodes, % [{Node, Pid}]
	  streamhosts,
	  waiting_for_streamhost = []
	 }).
-record(streamhost, {jid, state=unknown, last_queried=0, host, port}).
-define(STREAMHOST_QUERY_INTERVAL, 600).

%% API

get_streamhosts(Host) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    ?DEBUG("get_streamhosts ~p ~p",[Host,Proc]),
    {ok, Streamhosts} = gen_server:call(Proc, get_streamhosts),
    Streamhosts.

get_streamhost(Host, JID) ->
    Hosts = get_streamhosts(Host),
    lists:foldl(fun({JID2, _, _} = H, nil) when JID =:= JID2 ->
			H;
		   (_, R) ->
			R
		end, nil, Hosts).

%% Unused callbacks.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
%%----------------

start_link(Host, Opts) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    gen_server:start_link({local, Proc}, ?MODULE, [Host, Opts], []).

init([Host, Opts]) ->
    MyHost = gen_mod:get_opt_host(Host, Opts, "filestore.@HOST@"),
    ?DEBUG("Registering route for ~p",[MyHost]),
    ejabberd_router:register_route(MyHost),
    Nodes = [mod_filestore_node:start_link(Host, "public", MyHost, [public]),
	     mod_filestore_node:start_link(Host, "private", MyHost, [private])],
    {ok, #state{myhost = MyHost, nodes = Nodes, streamhosts = [#streamhost{jid = "proxy.localhost"}]}}.

terminate(_Reason, #state{myhost = MyHost}) ->
    ejabberd_router:unregister_route(MyHost),
    ok.

handle_call(get_streamhosts, From, #state{waiting_for_streamhost = Waiting} = State) ->
    ?DEBUG("get_streamhosts from ~p",[From]),
    gen_server:cast(self(), visit_waiting_for_streamhosts),
    {noreply, State#state{waiting_for_streamhost = [From | Waiting]}}.

handle_cast(visit_waiting_for_streamhosts,
	    #state{myhost = MyHost,
		   streamhosts = Streamhosts,
		   waiting_for_streamhost = [_ | _] = Waiting} = State) ->
    ?DEBUG("streamhosts: ~p",[Streamhosts]),
    {NowMS, NowS, _} = now(),
    Now = NowMS * 1000000 + NowS,
    MinLastQuery = Now - ?STREAMHOST_QUERY_INTERVAL,
    NewStreamhosts = lists:map(fun(#streamhost{jid = JID, state = SState, last_queried = LastQuery} = S)
				  when SState == unknown; LastQuery < MinLastQuery ->
				       ?DEBUG("querying streamhost ~p",[JID]),
				       ejabberd_router:route(jlib:string_to_jid(MyHost),
							     jlib:string_to_jid(JID),
							     jlib:iq_to_xml(#iq{type = get,
										sub_el = [{xmlelement, "query",
											   [{"xmlns", ?NS_BYTESTREAMS}], []}]
									       })),
				       S#streamhost{state = queried, last_queried = Now};
				  (S) ->
				       S
			       end, Streamhosts),
    case lists:foldl(fun(#streamhost{state = valid} = S, R) ->
			     [{S#streamhost.jid,
			       S#streamhost.host,
			       S#streamhost.port} | R];
			(_, R) ->
			     R
		     end, [], Streamhosts) of
	[] ->
	    NewWaiting = Waiting;
	ValidStreamhosts ->
	    lists:foreach(fun(WaitingPid) ->
				  gen_server:reply(WaitingPid, {ok, ValidStreamhosts})
			  end, Waiting),
	    NewWaiting = []
    end,
    {noreply, State#state{streamhosts = NewStreamhosts, waiting_for_streamhost = NewWaiting}};

handle_cast(_, State) ->
    {noreply, State}.

% Packet directed to component
handle_info({route, From, To = #jid{user = "", resource = ""}, Packet}, State) ->
    case Packet of
	{xmlelement, "iq", _, _} ->
	    IQ = jlib:iq_query_or_response_info(Packet),
	    case catch process_iq(From, IQ, State) of
		Result when is_record(Result, iq) ->
		    ejabberd_router:route(To, From, jlib:iq_to_xml(Result)),
		    {noreply, State};
		{'EXIT', Reason} when IQ#iq.type =/= error ->
		    ?ERROR_MSG("Error when processing IQ stanza: ~p", [Reason]),
		    Err = jlib:make_error_reply(Packet, ?ERR_INTERNAL_SERVER_ERROR),
		    ejabberd_router:route(To, From, Err),
		    {noreply, State};
		NewState when is_record(NewState, state) ->
		    {noreply, NewState};
		_ ->
		    {noreply, State}
	    end;
	_ ->
	    {noreply, State}
    end;

% Packet directed to node@component
handle_info({route, From, To = #jid{resource = ""}, Packet}=Info, State=#state{nodes = Nodes}) ->
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

%%%------------------------
%%% IQ Processing
%%%------------------------

-define(FEATURE(Var), {xmlelement, "feature", [{"var", Var}], []}).

%% disco#info request
process_iq(_, #iq{type = get, xmlns = ?NS_DISCO_INFO} = IQ, _) ->
    IQ#iq{type = result, sub_el =
	  [{xmlelement, "query",
	    [{"xmlns", ?NS_DISCO_INFO}],
	    [{xmlelement, "identity",
	      [{"category", "hierarchy"},
	       {"type", "branch"},
	       {"name", "Online File Storage"}],
	      []},
	     ?FEATURE(?NS_DISCO_INFO),
	     ?FEATURE(?NS_DISCO_ITEMS)
	    ]}]};

%% disco#items request
process_iq(_, #iq{type = get, xmlns = ?NS_DISCO_ITEMS} = IQ, #state{myhost = MyHost, nodes = Nodes}) ->
    IQ#iq{type = result, sub_el =
	  [{xmlelement, "query", [{"xmlns", ?NS_DISCO_ITEMS}],
	    lists:map(fun({Node, _Pid}) ->
			      {xmlelement, "item",
			       [{"name", Node},
				{"jid", Node ++ "@" ++ MyHost}],
			       []}
		      end, Nodes)
	   }]};

%% bytestreams query reply
process_iq(From,
	   #iq{type = Type,
	       xmlns = ?NS_BYTESTREAMS,
	       sub_el = [SubEl | _]},
	   #state{streamhosts = Streamhosts} = State)
  when Type == result; Type == error ->
    case Type of
	result ->
	    % TODO: catch errors
	    {xmlelement, "streamhost", StreamhostAttrs, _} = xml:get_subtag(SubEl, "streamhost"),
	    case xml:get_attr_s("jid", StreamhostAttrs) of
		"" -> JID = From;
		JID2 -> JID = JID2
	    end,
	    Host = xml:get_attr_s("host", StreamhostAttrs),
	    {Port, ""} = string:to_integer(xml:get_attr_s("port", StreamhostAttrs)),
	    Streamhost = #streamhost{jid = JID, state = valid, host = Host, port = Port};
	error ->
	    Streamhost = #streamhost{jid = From, state = error}
    end,
    FromS = jlib:jid_to_string(From),
    NewStreamhosts = lists:map(fun(#streamhost{jid = JID, last_queried = LastQueried})
				  when JID =:= FromS ->
				       Streamhost#streamhost{last_queried = LastQueried};
				  (OtherStreamhost) ->
				       OtherStreamhost
			       end, Streamhosts),
    gen_server:cast(self(), visit_waiting_for_streamhosts),
    State#state{streamhosts = NewStreamhosts};

%% Unknown "set" or "get" request
process_iq(_, #iq{type=Type, sub_el=SubEl} = IQ, _) when Type==get; Type==set ->
    ?DEBUG("unknown IQ: ~p",[IQ]),
    IQ#iq{type = error, sub_el = [SubEl, ?ERR_SERVICE_UNAVAILABLE]};

%% IQ "result" or "error".
process_iq(_, _, _) ->
    ok.
