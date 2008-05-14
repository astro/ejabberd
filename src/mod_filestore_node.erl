%%%-------------------------------------------------------------------
-module(mod_filestore_node).

-behaviour(gen_server).

%% API
-export([start_link/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(state, {my_jid, opts, basepath, transfers}).
-record(transfer, {jid_sid, state, filename, filesize, stream_pid, request_stanza}).

-include("ejabberd.hrl").
-include("jlib.hrl").

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {Node,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start_link(Node, Host, Opts) ->
    {ok, Pid} = gen_server:start_link(?MODULE, [jlib:make_jid(Node, Host, ""), Opts], []),
    {Node, Pid}.

%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the server
%%--------------------------------------------------------------------
init([MyJID, Opts]) ->
    Basepath = "/tmp/" ++ jlib:jid_to_string(MyJID),
    file:make_dir(Basepath),

    process_flag(trap_exit, true),
    Transfers = ets:new(transfers, [set, {keypos, #state.my_jid}]),
    {ok, #state{basepath = Basepath, my_jid = MyJID, opts = Opts, transfers = Transfers}}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast({route, From, To, {xmlelement, "iq", _, _} = Packet}, State) ->
    IQ = jlib:iq_query_info(Packet),
    case catch process_iq(From, IQ, State) of
	Result when is_record(Result, iq) ->
	    ejabberd_router:route(To, From, jlib:iq_to_xml(Result));
	{'EXIT', Reason} ->
	    ?ERROR_MSG("Error when processing IQ stanza: ~p", [Reason]),
	    Err = jlib:make_error_reply(Packet, ?ERR_INTERNAL_SERVER_ERROR),
	    ejabberd_router:route(To, From, Err);
	_ ->
	    ok
    end,
    {noreply, State};

handle_cast({streamhost_connected, StreamPid, {JID, Host, Port}},
	    State = #state{my_jid = MyJID, transfers = Transfers}) ->
    case transfer_by_stream_pid(StreamPid, Transfers) of
	Transfer = #transfer{state = connecting,
			     jid_sid = {From, SID},
			     request_stanza = IQ,
			     filename = FileName,
			     filesize = FileSize} ->
	    PortS = io_lib:format("~B", [Port]),
	    Reply = IQ#iq{type = result,
			  sub_el = [{xmlelement, "query",
				     [{"xmlns", ?NS_BYTESTREAMS},
				      {"mode", "tcp"},
				      {"sid", SID}],
				     [{xmlelement, "streamhost-used",
				       [{"jid", JID},
					{"host", Host},
					{"port", PortS}], []}
				     ]}]
			 },
	    ejabberd_router:route(MyJID, From, jlib:iq_to_xml(Reply)),
	    ets:insert(Transfers, Transfer#transfer{state = receiving,
						    request_stanza = undefined}),
	    gen_fsm:send_event(StreamPid, {receive_file, file_path(State, FileName), FileSize});
	error ->
	    ignore
    end,
    {noreply, State};

handle_cast(_Msg, State) ->
    ?DEBUG("cast: ~p",[_Msg]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info({'EXIT', Pid, Reason},
	    State = #state{my_jid = MyJID, transfers = Transfers}) ->
    case transfer_by_stream_pid(Pid, Transfers) of
	Transfer = #transfer{jid_sid = {From, _}, request_stanza = IQ} ->
	    ets:delete(Transfers, Transfer#transfer.jid_sid),
	    if
		is_record(IQ, iq) ->
		    Packet = jlib:iq_to_xml(IQ),
		    case Reason of
			cannot_connect ->
			    Err = jlib:make_error_reply(Packet, ?ERR_REMOTE_SERVER_NOT_FOUND);
			_ ->
			    Err = jlib:make_error_reply(Packet, ?ERR_INTERNAL_SERVER_ERROR)
		    end,
		    ejabberd_router:route(MyJID, From, Err);
		true ->
		    ok
	    end,
	    {noreply, State};
	error ->
	    {stop, exit, State}
    end;

handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

%%%------------------------
%%% IQ Processing
%%%------------------------

%% disco#info request
process_iq(_, #iq{type = get, xmlns = ?NS_DISCO_INFO} = IQ, _) ->
    IQ#iq{type = result, sub_el =
	  [{xmlelement, "query", [{"xmlns", ?NS_DISCO_INFO}], []}]};

%% disco#items request
process_iq(_, #iq{type = get, xmlns = ?NS_DISCO_ITEMS} = IQ, _) ->
    IQ#iq{type = result, sub_el =
	  [{xmlelement, "query", [{"xmlns", ?NS_DISCO_ITEMS}], []}]};

%% File-transfer offer
process_iq(From,
	   #iq{type = set, xmlns = ?NS_STREAM_INITIATION, sub_el = {xmlelement, "si", SIAttrs, _} = SubEl} = IQ,
	   #state{transfers = Transfers}) ->
    SID = xml:get_attr_s("id", SIAttrs),
    %?NS_STREAM_INITIATION = xml:get_attr_s("xmlns", SIAttrs),
    ?PROFILE_FILE_TRANSFER = xml:get_attr_s("profile", SIAttrs),
    
    {xmlelement, "file", FileAttrs, _} = xml:get_subtag(SubEl, "file"),
    FileName = xml:get_attr_s("name", FileAttrs),
    FileSizeS = xml:get_attr_s("size", FileAttrs),
    {FileSize, ""} = string:to_integer(FileSizeS),
    
    StreamMethods = si_find_stream_methods(SubEl),
    true = lists:member(?NS_BYTESTREAMS, StreamMethods),
    
    ets:insert(Transfers, #transfer{jid_sid = {From, SID},
				    state = offered,
				    filename = FileName,
				    filesize = FileSize}),
    
    IQ#iq{type = result, sub_el = [{xmlelement, "si",
				    [{"xmlns", ?NS_STREAM_INITIATION}],
				    [{xmlelement, "feature",
				      [{"xmlns", ?NS_FEATURE_NEG}],
				      [{xmlelement, "x",
					[{"xmlns", ?NS_XDATA},
					 {"type", "submit"}],
					[{xmlelement, "field",
					  [{"var", "stream-method"}],
					  [{xmlelement, "value",
					    [],
					    [{xmlcdata, ?NS_BYTESTREAMS}]}
					  ]}
					]}
				      ]}
				    ]}
				  ]};

%% Bytestreams initiation
process_iq(From,
	   #iq{type = set, xmlns = ?NS_BYTESTREAMS, sub_el = {xmlelement, "query", QueryAttrs, QueryChildren} = SubEl} = IQ,
	   #state{my_jid = MyJID, transfers = Transfers}) ->
    SID = xml:get_attr_s("sid", QueryAttrs),
    case ets:lookup(Transfers, {From, SID}) of
	[#transfer{state = offered} = Transfer] ->
	    case xml:get_attr_s("mode", QueryAttrs) of
		Mode when Mode == ""; Mode == "tcp" ->
		    StreamHosts = bytestreams_query_streamhosts(QueryChildren),
		    Target = jlib:jid_to_string(jlib:jid_tolower(MyJID)),
		    Initiator = jlib:jid_to_string(jlib:jid_tolower(From)),
		    SHA1 = sha:sha(SID ++ Initiator ++ Target),
		    {ok, StreamPid} = mod_filestore_stream:start_link(self(), StreamHosts, SHA1),
		    ets:insert(Transfers, Transfer#transfer{state = connecting,
							    stream_pid = StreamPid,
							    request_stanza = IQ}),
		    ok;
		_ -> % Mode == "udp" or something else
		    ets:delete(Transfers, {From, SID}),
		    IQ#iq{type = error, sub_el = [SubEl, ?ERR_NOT_ACCEPTABLE]}
	    end;
	[] ->
	    IQ#iq{type = error, sub_el = [SubEl, ?ERR_UNEXPECTED_REQUEST]}
    end;

%% Unknown "set" or "get" request
process_iq(_, #iq{type=Type, sub_el=SubEl} = IQ, _) when Type==get; Type==set ->
    ?DEBUG("unknown IQ: ~p",[IQ]),
    IQ#iq{type = error, sub_el = [SubEl, ?ERR_SERVICE_UNAVAILABLE]};

%% IQ "result" or "error".
process_iq(_, _, _) ->
    ok.

si_find_stream_methods(SI) ->
    {xmlelement, "feature", FeatureNegAttrs, FeatureNegChildren} = xml:get_subtag(SI, "feature"),
    ?NS_FEATURE_NEG = xml:get_attr_s("xmlns", FeatureNegAttrs),
    lists:foldl(fun({xmlelement, "x", XAttrs, XChildren}, R) ->
			case {xml:get_attr_s("xmlns", XAttrs), xml:get_attr_s("type", XAttrs)} of
			    {?NS_XDATA, "form"} ->
				R ++ xdata_fields_find_stream_methods(XChildren);
			    _ ->
				R
			end;
		   (_, R) ->
			R
		end, [], FeatureNegChildren).

xdata_fields_find_stream_methods([{xmlelement, "field", FieldAttrs, FieldChildren} | Els]) ->
    case xml:get_attr_s("var", FieldAttrs) of
	"stream-method" ->
	    lists:foldl(fun({xmlelement, "option", _, _} = OptionEl, R) ->
				[xml:get_subtag_cdata(OptionEl, "value") | R];
			   (_, R) ->
				R
			end, [], FieldChildren);
	_ ->
	    xdata_fields_find_stream_methods(Els)
    end;
xdata_fields_find_stream_methods([_ | Children]) ->
    xdata_fields_find_stream_methods(Children);
xdata_fields_find_stream_methods([]) ->
    [].

bytestreams_query_streamhosts(QueryChildren) ->
    lists:foldr(fun({xmlelement, "streamhost", StreamHostAttrs, _}, R) ->
			JID = xml:get_attr_s("jid", StreamHostAttrs),
			Host = xml:get_attr_s("host", StreamHostAttrs),
			PortS = xml:get_attr_s("port", StreamHostAttrs),
			case {JID, Host, string:to_integer(PortS)} of
			    {[_ | _], [_ | _], {Port, ""}} when is_integer(Port) ->
				[{JID, Host, Port} | R];
			    _ ->
				R
			end;
		   (_, R) ->
			R
		end, [], QueryChildren).

transfer_by_stream_pid(StreamPid, Transfers) ->
    ets:foldl(fun(T = #transfer{stream_pid = Pid}, error) when Pid == StreamPid ->
		      T;
		 (_, R) ->
		      R
	      end, error, Transfers).

file_path(#state{basepath = Basepath}, FilePath) ->
    FileName = lists:last(string:tokens(FilePath, "/")),
    Basepath ++ "/" ++ FileName.

