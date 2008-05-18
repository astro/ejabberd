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

-include_lib("kernel/include/file.hrl").
-include("ejabberd.hrl").
-include("jlib.hrl").
-include("adhoc.hrl").

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
	    file:make_dir(user_path(State, From)),
	    gen_fsm:send_event(StreamPid, {receive_file, file_path(State, From, FileName), FileSize});
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
	    ?DEBUG("Transfer of ~p ended.", [Transfer#transfer.filename]),
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

-define(IDENTITY(Category, Type, Name), {xmlelement, "identity",
					 [{"category", Category},
					  {"type", Type},
					  {"name", Name}], []}).
-define(FEATURE(Var), {xmlelement, "feature", [{"var", Var}], []}).
-define(ITEM(JID, Node, Name), {xmlelement, "item",
				[{"jid", case JID of
					     #jid{} -> jlib:jid_to_string(JID);
					     _ -> JID
					 end},
				 {"node", Node},
				 {"name", Name}], []}).

%% disco#info request
process_iq(_, #iq{type = get, xmlns = ?NS_DISCO_INFO, sub_el = {xmlelement, "query", QueryAttrs, _}} = IQ, _) ->
    Node = xml:get_attr_s("node", QueryAttrs),
    Info = case Node of
	       "" ->
		   [
		    ?IDENTITY("store", "file", "File Storage"),
		    ?FEATURE(?NS_DISCO_INFO),
		    ?FEATURE(?NS_DISCO_ITEMS),
		    ?FEATURE(?NS_BYTESTREAMS),
		    ?FEATURE(?NS_STREAM_INITIATION),
		    ?FEATURE("presence"),
		    ?FEATURE(?NS_COMMANDS),
		    ?FEATURE(?NS_XDATA)
		   ];
	       ?NS_COMMANDS ->
		   [
		    ?IDENTITY("automation", "command-node", "File operations"),
		    ?FEATURE(?NS_COMMANDS),
		    ?FEATURE(?NS_XDATA)
		   ];
	       _ ->
		   []
	   end,
    IQ#iq{type = result, sub_el =
	  [{xmlelement, "query",
	    [{"xmlns", ?NS_DISCO_INFO},
	     {"node", Node}],
	    Info}]};

%% disco#items request
process_iq(_, #iq{type = get, xmlns = ?NS_DISCO_ITEMS, sub_el = {xmlelement, "query", QueryAttrs, _}} = IQ, #state{my_jid = MyJID}) ->
    Node = xml:get_attr_s("node", QueryAttrs),
    Items = case Node of
		"" ->
		    [
		     ?ITEM(MyJID, ?NS_COMMANDS, "File operations")
		    ];
		?NS_COMMANDS ->
		    [
		     ?ITEM(MyJID, "browse", "Browse and retrieve files"),
		     ?ITEM(MyJID, "delete", "Delete files")
		    ];
		_ ->
		    []
	    end,
    IQ#iq{type = result, sub_el =
	  [{xmlelement, "query",
	    [{"xmlns", ?NS_DISCO_ITEMS},
	     {"node", Node}],
	    Items}]};

%% Command execution
process_iq(From, #iq{type = set, xmlns = ?NS_COMMANDS, sub_el = SubEl} = IQ, State) ->
    case adhoc:parse_request(IQ) of
	{error, Err} ->
	    IQ#iq{type = error, sub_el = [SubEl, Err]};
	#adhoc_request{} = Req ->
	    #adhoc_response{} = Resp = process_adhoc(From, Req, State),
	    IQ#iq{type = result, sub_el = [adhoc:produce_response(Resp)]}
    end;

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
				    state = offer_received,
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
	[#transfer{state = offer_received} = Transfer] ->
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

process_adhoc(_, #adhoc_request{action = "cancel", node = Node}, _) ->
    #adhoc_response{status = canceled, node = Node};

process_adhoc(_, #adhoc_request{node = "browse", xdata = false}, _) ->
    #adhoc_response{node = "browse",
		    status = executing,
		    defaultaction = "next", actions = ["next"],
		    elements = [{xmlelement, "x",
				 [{"xmlns", ?NS_XDATA},
				  {"type", "form"}],
				 [{xmlelement, "title", [],
				   [{xmlcdata, "Browse/get files of a user"}]},
				  {xmlelement, "instructions", [],
				   [{xmlcdata, "Enter the Jabber-Id of the user whose files you want to browse."}]},
				  {xmlelement, "field",
				   [{"var", "jid"},
				    {"label", "Jabber-Id"},
				    {"type", "jid-single"}], []}
				  ]}]
		    };

process_adhoc(From, #adhoc_request{node = "browse",
				   xdata = XData}, State) ->
    FieldValues = jlib:parse_xdata_submit(XData),
    {value, {"jid", [JID]}} = lists:keysearch("jid", 1, FieldValues),
    case lists:keysearch("files", 1, FieldValues) of
	false ->
	    #adhoc_response{node = "browse",
			    status = executing,
						% TODO: prev
			    defaultaction = "complete", actions = ["complete"],
			    elements = [{xmlelement, "x",
					 [{"xmlns", ?NS_XDATA},
					  {"type", "form"}],
					 [{xmlelement, "title", [],
					   [{xmlcdata, "Browse/get files of user " ++ JID}]},
					  {xmlelement, "instructions", [],
					   [{xmlcdata, "Select the files you would like to receive."}]},
					  {xmlelement, "field",
					   [{"var", "jid"},
					    {"type", "hidden"}],
					   [{xmlelement, "value", [],
					     [{xmlcdata, JID}]}]},
					  {xmlelement, "field",
					   [{"var", "files"},
					    {"label", "Files"},
					    {"type", "list-multi"}],
					   lists:map(fun({File, Size}) ->
							     {xmlelement, "option",
							      [{"label", io_lib:format("~s (~B Bytes)", [File, Size])}],
							      [{xmlelement, "value", [],
								[{xmlcdata, File}]}]}
						     end, user_files(State, JID))
					  }]}]
			   };
	{value, {"files", Files}} ->
	    lists:foreach(fun(File) ->
				  offer_file(From, file_path(State, JID, File), State)
			  end, Files),
	    #adhoc_response{node = "browse",
			    status = completed}
    end;

process_adhoc(_, R, _) ->
    ?DEBUG("Unknown adhoc response: ~p",[R]).

offer_file(To, FilePath, #state{my_jid = MyJID, transfers = Transfers}) ->
    SID = randoms:get_string(),
    {ok, #file_info{size = FileSize}} = file:read_file_info(FilePath),
    IQ = #iq{id = randoms:get_string(),
	     type = set,
	     sub_el = [{xmlelement, "si",
			[{"xmlns", ?NS_STREAM_INITIATION},
			 {"id", SID},
			 {"profile", ?PROFILE_FILE_TRANSFER}],
			[{xmlelement, "file",
			  [{"xmlns", ?NS_FILE_TRANSFER},
			   {"name", lists:last(string:tokens(FilePath, "/"))},
			   {"size", io_lib:format("~B", [FileSize])}],
			  []},
			 {xmlelement, "feature",
			  [{"xmlns", ?NS_FEATURE_NEG}],
			  [{xmlelement, "x",
			    [{"xmlns", ?NS_XDATA},
			     {"type", "form"}],
			    [{xmlelement, "field",
			      [{"var", "stream-method"},
			       {"type", "list-single"}],
			      [{xmlelement, "option", [],
				[{xmlelement, "value", [],
				  [{xmlcdata, ?NS_BYTESTREAMS}]
				  }]}]}]}]
			  }]}]},
    ejabberd_router:route(MyJID, To, jlib:iq_to_xml(IQ)),
    ets:insert(Transfers, #transfer{jid_sid = {To, SID},
				    filename = FilePath,
				    filesize = FileSize,
				    state = offer_sent,
				    request_stanza = IQ}),
    ok.

%%
%% Helper functions
%%

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

%%
%% File location
%%

file_path(State, JID, FilePath) ->
    UserPath = user_path(State, JID),
    FileName = lists:last(string:tokens(FilePath, "/")),
    [_ | _] = FileName,
    true = (FileName =/= "."),
    true = (FileName =/= ".."),
    UserPath ++ "/" ++ FileName.

user_path(#state{basepath = Basepath},
	  #jid{user = User, server = Server}) ->
    UserName = jlib:jid_to_string(#jid{user = User, server = Server, resource = ""}),
    UserName2 = lists:last(string:tokens(UserName, "/")),
    [_ | _] = UserName2,
    true = (UserName2 =/= "."),
    true = (UserName2 =/= ".."),
    Basepath ++ "/" ++ UserName2;
user_path(State, JID) when is_list(JID) ->
    user_path(State, jlib:string_to_jid(JID)).

% -> [{Name, Size}]
user_files(State, JID) ->
    UserPath = user_path(State, JID),
    case file:list_dir(UserPath) of
	{ok, Files} ->
	    lists:map(fun(File) ->
			      case file:read_file_info(UserPath ++ "/" ++ File) of
				  {ok, #file_info{size = Size}} -> FileSize = Size;
				  _ -> FileSize = 0
			      end,
			      {File, FileSize}
		      end, Files);
	{error, _} ->
	    []
    end.

% TODO: quota with transfers
