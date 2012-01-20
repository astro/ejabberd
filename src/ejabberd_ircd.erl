-module(ejabberd_ircd).
-author('henoch@dtek.chalmers.se').
-update_info({update, 0}).

-behaviour(gen_fsm).

%% External exports
-export([start/2,
	 start_link/2,
	 socket_type/0]).

%% gen_fsm callbacks
-export([init/1,
	 wait_for_login/2,
	 wait_for_cmd/2,
	 handle_event/3,
	 handle_sync_event/4,
	 code_change/4,
	 handle_info/3,
	 terminate/3
	]).

%-define(ejabberd_debug, true).

-include("ejabberd.hrl").
-include("jlib.hrl").

-define(DICT, dict).

-record(state, {socket,
		sockmod,
		access,
		encoding,
		shaper,
		host,
		muc_host,
		sid = none,
		pass = "",
		nick = none,
		user = none,
		realname = none,
		%% joining is a mapping from room JIDs to nicknames
		%% received but not yet forwarded
		joining = ?DICT:new(),
		joined = ?DICT:new(),
		%% mapping certain channels to certain rooms
		channels_to_jids = ?DICT:new(),
		jids_to_channels = ?DICT:new(),
		%% maps /iq/@id to {ReplyFun/1, expire timestamp
		outgoing_requests = ?DICT:new(),
		%% maps to #seen per channel
		seen = ?DICT:new(),
		quit_msg
	       }).
-record(channel, {participants = [],
		  topic = ""}).

-record(seen, {status, show, role}).

-record(line, {prefix, command, params}).

%-define(DBGFSM, true).

-ifdef(DBGFSM).
-define(FSMOPTS, [{debug, [trace]}]).
-else.
-define(FSMOPTS, []).
-endif.

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------
start(SockData, Opts) ->
    supervisor:start_child(ejabberd_ircd_sup, [SockData, Opts]).

start_link(SockData, Opts) ->
    gen_fsm:start_link(ejabberd_ircd, [SockData, Opts], ?FSMOPTS).

socket_type() ->
    raw.

%%%----------------------------------------------------------------------
%%% Callback functions from gen_fsm
%%%----------------------------------------------------------------------

%%----------------------------------------------------------------------
%% Func: init/1
%% Returns: {ok, StateName, StateData}          |
%%          {ok, StateName, StateData, Timeout} |
%%          ignore                              |
%%          {stop, StopReason}
%%----------------------------------------------------------------------
init([{SockMod, Socket}, Opts]) ->
    iconv:start(),
    Access = case lists:keysearch(access, 1, Opts) of
		 {value, {_, A}} -> A;
		 _ -> all
	     end,
    Shaper = case lists:keysearch(shaper, 1, Opts) of
		 {value, {_, S}} -> S;
		 _ -> none
	     end,
    Host = case lists:keysearch(host, 1, Opts) of
	       {value, {_, H}} -> H;
	       _ -> ?MYNAME
	   end,
    MucHost = case lists:keysearch(muc_host, 1, Opts) of
		  {value, {_, M}} -> M;
		  _ -> "conference." ++ ?MYNAME
	      end,
    Encoding = case lists:keysearch(encoding, 1, Opts) of
		   {value, {_, E}} -> E;
		   _ -> "utf-8"
	       end,
    ChannelMappings = case lists:keysearch(mappings, 1, Opts) of
			  {value, {_, C}} -> C;
			  _ -> []
		      end,
    {ChannelToJid, JidToChannel} =
	lists:foldl(fun({Channel, Room}, {CToJ, JToC}) ->
			    RoomJID = jlib:string_to_jid(Room),
			    BareChannel = case Channel of
					      [$#|R] -> R;
					      _ -> Channel
					  end,
			    {?DICT:store(BareChannel, RoomJID, CToJ),
			     ?DICT:store(RoomJID, BareChannel, JToC)}
		    end, {?DICT:new(), ?DICT:new()},
		    ChannelMappings),
    inet:setopts(Socket, [list, {packet, line}, {active, true}]),
    %%_ReceiverPid = start_ircd_receiver(Socket, SockMod),
    {ok, wait_for_login, #state{socket    = Socket,
			       sockmod   = SockMod,
			       access    = Access,
			       encoding  = Encoding,
			       shaper    = Shaper,
			       host      = Host,
			       muc_host  = MucHost,
			       channels_to_jids = ChannelToJid,
			       jids_to_channels = JidToChannel
			      }}.

handle_info({tcp, _Socket, Line}, StateName, StateData) ->
    DecodedLine = iconv:convert(StateData#state.encoding, "utf-8", Line),
    Parsed = parse_line(DecodedLine),
    ?MODULE:StateName({line, Parsed}, StateData);
handle_info({tcp_closed, _}, _StateName, StateData) ->
    {stop, normal, StateData#state{quit_msg = "Connection closed"}};
handle_info({route, _, _, _} = Event, StateName, StateData) ->
    ?MODULE:StateName(Event, StateData);
handle_info(replaced, _StateName, #state{nick = Nick} = StateData) ->
    send_line("KILL " ++ Nick ++ " (Replaced)", StateData),
    {stop, normal, StateData#state{quit_msg = "Session replaced"}};
handle_info(Info, StateName, StateData) ->
    ?ERROR_MSG("Unexpected info: ~p", [Info]),
    {next_state, StateName, StateData}.

handle_sync_event(Event, _From, StateName, StateData) ->
    ?ERROR_MSG("Unexpected sync event: ~p", [Event]),
    Reply = ok,
    {reply, Reply, StateName, StateData}.

handle_event(_Event, StateName, StateData) ->
    {next_state, StateName, StateData}.

code_change(_OldVsn, StateName, StateData, _Extra) ->
    {ok, StateName, StateData}.
terminate(_Reason, _StateName, #state{socket = Socket, sockmod = SockMod,
				      sid = SID, nick = Nick,
				      quit_msg = [_ | _] = QuitMsg} = State) ->
    ?INFO_MSG("closing IRC connection for ~p", [Nick]),
    case SID of
	none ->
	    ok;
	_ ->
	    Packet = {xmlelement, "presence",
		      [{"type", "unavailable"}],
		      [
		       {xmlelement, "status", [],
			[{xmlcdata, QuitMsg}]}
		      ]},
	    FromJID = user_jid(State),
	    foreach_channel(fun(ChannelJID, _ChannelData) ->
				    ejabberd_router:route(FromJID, ChannelJID, Packet)
			    end, State),
	    ejabberd_sm:close_session_unset_presence(SID, FromJID#jid.user,
						     FromJID#jid.server, FromJID#jid.resource,
						     QuitMsg)
    end,
    gen_tcp = SockMod,
    ok = gen_tcp:close(Socket),
    ok;
terminate(Reason, StateName, StateData) ->
    terminate(Reason, StateName, StateData#state{quit_msg = "Session terminated"}).

wait_for_login({line, #line{command = "PASS", params = [Pass | _]}}, State) ->
    {next_state, wait_for_login, State#state{pass = Pass}};

wait_for_login({line, #line{command = "NICK", params = [Nick | _]}}, State) ->
    wait_for_login(info_available, State#state{nick = Nick});

wait_for_login({line, #line{command = "USER", params = [User, _Host, _Server, Realname]}}, State) ->
    wait_for_login(info_available, State#state{user = User,
					       realname = Realname});
wait_for_login(info_available, #state{host = Server,
				      nick = Nick,
				      pass = Pass,
				      user = User,
				      realname = Realname} = State)
  when Nick =/= none andalso
       User =/= none andalso
       Realname =/= none ->
    JID = user_jid(State),
    case JID of
	error ->
	    ?DEBUG("invalid nick '~p'", [Nick]),
	    send_reply('ERR_ERRONEUSNICKNAME', [Nick, "Erroneous nickname"], State),
	    {next_state, wait_for_login, State};
	_ ->
	    case acl:match_rule(Server, State#state.access, JID) of
		deny ->
		    ?DEBUG("access denied for '~p'", [Nick]),
		    send_reply('ERR_NICKCOLLISION', [Nick, "Nickname collision"], State),
		    {next_state, wait_for_login, State};
		allow ->
		    case ejabberd_auth:check_password(Nick, Server, Pass) of
			false ->
			    ?DEBUG("auth failed for '~p'", [Nick]),
			    send_reply('ERR_NICKCOLLISION', [Nick, "Authentication failed"], State),
			    {next_state, wait_for_login, State};
			true ->
			    ?DEBUG("good nickname '~p'", [Nick]),
			    SID = {now(), self()},
			    Info = [{ip, peerip(gen_tcp, State#state.socket)}, {conn, irc}],
			    ejabberd_sm:open_session(
			      SID, JID#jid.user, JID#jid.server, JID#jid.resource, Info),
			    send_text_command("", "001", [Nick, "IRC interface of ejabberd server "++Server], State),
			    send_reply('RPL_MOTDSTART', [Nick, "- "++Server++" Message of the day - "], State),
			    send_reply('RPL_MOTD', [Nick, "- This is the IRC interface of the ejabberd server "++Server++"."], State),
			    send_reply('RPL_MOTD', [Nick, "- Your full JID is "++Nick++"@"++Server++"/irc."], State),
			    send_reply('RPL_MOTD', [Nick, "- Channel #whatever corresponds to MUC room whatever@"++State#state.muc_host++"."], State),
			    send_reply('RPL_MOTD', [Nick, "- This IRC interface is quite immature.  You will probably find bugs."], State),
			    send_reply('RPL_MOTD', [Nick, "- Have a good time!"], State),
			    send_reply('RPL_ENDOFMOTD', [Nick, "End of /MOTD command"], State),
			    {next_state, wait_for_cmd, State#state{nick = Nick, sid = SID, pass = ""}}
		    end
	    end
    end;
wait_for_login(info_available, State) ->
    %% Ignore if either NICK or USER is pending
    {next_state, wait_for_login, State};

wait_for_login(Event, State) ->
    ?DEBUG("in wait_for_login", []),
    ?INFO_MSG("unexpected event ~p", [Event]),
    {next_state, wait_for_login, State}.

peerip(SockMod, Socket) ->
    IP = case SockMod of
	     gen_tcp -> inet:peername(Socket);
	     _ -> SockMod:peername(Socket)
	 end,
    case IP of
	{ok, IPOK} -> IPOK;
	_ -> undefined
    end.

wait_for_cmd({line, #line{command = "USER", params = [_Username, _Hostname, _Servername, _Realname]}}, State) ->
    %% Yeah, like we care.
    {next_state, wait_for_cmd, State};
wait_for_cmd({line, #line{command = "JOIN", params = Params}}, State) ->
    {ChannelsString, KeysString} =
	case Params of
	    [C, K] ->
		{C, K};
	    [C] ->
		{C, []}
	end,
    Channels = string:tokens(ChannelsString, ","),
    Keys = string:tokens(KeysString, ","),
    NewState = join_channels(Channels, Keys, State),
    {next_state, wait_for_cmd, NewState};

wait_for_cmd({line, #line{command = "PART", params = [ChannelsString | MaybeMessage]}}, State) ->
    Message = case MaybeMessage of
		  [] -> nothing;
		  [M] -> M
	      end,
    Channels = string:tokens(ChannelsString, ","),
    NewState = part_channels(Channels, State, Message),
    {next_state, wait_for_cmd, NewState};

wait_for_cmd({line, #line{command = "PRIVMSG", params = [To, Text]}}, State) ->
    Recipients = string:tokens(To, ","),
    FromJID = user_jid(State),
    lists:foreach(
      fun(Rcpt) ->
	      case Rcpt of
		  [$# | Roomname] ->
		      Packet = {xmlelement, "message",
				[{"type", "groupchat"}],
				[{xmlelement, "body", [],
				  filter_cdata(translate_action(Text))}]},
		      ToJID = channel_to_jid(Roomname, State),
		      ejabberd_router:route(FromJID, ToJID, Packet);
		  _ ->
		      case string:tokens(Rcpt, "#") of
			  [Nick, Channel] ->
			      Packet = {xmlelement, "message",
					[{"type", "chat"}],
					[{xmlelement, "body", [],
					  filter_cdata(translate_action(Text))}]},
			      ToJID = channel_nick_to_jid(Nick, Channel, State),
			      ejabberd_router:route(FromJID, ToJID, Packet);
			  _ ->
			      send_text_command(Rcpt, "NOTICE", [State#state.nick,
								 "Your message to "++
								 Rcpt++
								 " was dropped.  "
								 "Try sending it to "++Rcpt++
								 "#somechannel."], State)
		      end
	      end
      end, Recipients),
    {next_state, wait_for_cmd, State};

wait_for_cmd({line, #line{command = "PING", params = Params}}, State) ->
    {Token, Whom} =
	case Params of
	    [A] ->
		{A, ""};
	    [A, B] ->
		{A, B}
	end,
    if Whom == ""; Whom == State#state.host ->
	    %% Ping to us
	    send_command("", "PONG", [State#state.host, Token], State);
       true ->
	    %% Ping to someone else
	    ?DEBUG("ignoring ping to ~s", [Whom]),
	    ok
    end,
    {next_state, wait_for_cmd, State};

wait_for_cmd({line, #line{command = "TOPIC", params = Params}}, State) ->
    case Params of
	[Channel] ->
	    %% user asks for topic
	    case ?DICT:find(channel_to_jid(Channel, State),
			    State#state.joined) of
		{ok, #channel{topic = Topic}} ->
		    case Topic of
			"" ->
			    send_reply('RPL_NOTOPIC', ["No topic is set"], State);
			_ ->
			    send_reply('RPL_TOPIC', [Topic], State)
		    end;
		_ ->
		    send_reply('ERR_NOTONCHANNEL', ["You're not on that channel"], State)
	    end;
	[Channel, NewTopic] ->
	    Packet =
		{xmlelement, "message",
		 [{"type", "groupchat"}],
		 [{xmlelement, "subject", [], filter_cdata(NewTopic)}]},
	    FromJID = user_jid(State),
	    ToJID = channel_to_jid(Channel, State),
	    ejabberd_router:route(FromJID, ToJID, Packet)
    end,
    {next_state, wait_for_cmd, State};

wait_for_cmd({line, #line{command = "MODE", params = [ModeOf | Params]}}, State) ->
    case ModeOf of
	[$# | Channel] ->
	    ChannelJid = channel_to_jid(Channel, State),
	    Joined = ?DICT:find(ChannelJid, State#state.joined),
	    case Joined of
		{ok, _ChannelData} ->
		    case Params of
			[] ->
			    %% This is where we could mirror some advanced MUC
			    %% properties.
			    %%send_reply('RPL_CHANNELMODEIS', [Channel, Modes], State);
			    send_reply('ERR_NOCHANMODES', [Channel], State);
			["b"] ->
			    send_reply('RPL_ENDOFBANLIST', [Channel, "Ban list not available"], State);
			_ ->
			    send_reply('ERR_UNKNOWNCOMMAND', ["MODE", io_lib:format("MODE ~p not understood", [Params])], State)
		    end;
		_ ->
		    send_reply('ERR_NOTONCHANNEL', [Channel, "You're not on that channel"], State)
	    end;
	Nick ->
	    if Nick == State#state.nick ->
		    case Params of
			[] ->
			    send_reply('RPL_UMODEIS', [], State);
			[Flags|_] ->
			    send_reply('ERR_UMODEUNKNOWNFLAG', [Flags, "No MODE flags supported"], State)
		    end;
	       true ->
		    send_reply('ERR_USERSDONTMATCH', ["Can't change mode for other users"], State)
	    end
    end,
    {next_state, wait_for_cmd, State};

wait_for_cmd({line, #line{command = "NICK", params = [NewNick | _]}}, State) ->
    Joined =
	?DICT:size(State#state.joining) == 0 andalso
	?DICT:size(State#state.joined) == 0,
    if
	Joined ->
	    OldNick = State#state.nick,
	    OldMe = OldNick ++ "!" ++ OldNick ++ "@" ++ State#state.host,
	    NewState = State#state{nick = NewNick},
	    send_text_command(OldMe, "NICK", [NewNick], NewState),
	    {next_state, wait_for_cmd, NewState};
	true ->
	    send_reply('ERR_NICKCOLLISION', [NewNick, "Cannot change nickname while in channel"], State),
	    {next_state, wait_for_cmd, State}
    end;

wait_for_cmd({line, #line{command = "LIST"}}, #state{nick = Nick} = State) ->
    Id = randoms:get_string(),
    ejabberd_router:route(user_jid(State), jlib:make_jid("", State#state.muc_host, ""),
			  {xmlelement, "iq", [{"type", "get"},
					      {"id", Id}],
			   [{xmlelement, "query",
			     [{"xmlns", ?NS_DISCO_ITEMS}], []}
			   ]}),
    F = fun(Reply, State2) ->
		Type = xml:get_tag_attr_s("type", Reply),
		Xmlns = xml:get_path_s(Reply, [{elem, "query"}, {attr, "xmlns"}]),
		case {Type, Xmlns} of
		    {"result", ?NS_DISCO_ITEMS} ->
			{xmlelement, _, _, Items} = xml:get_subtag(Reply, "query"),
			send_reply('RPL_LISTSTART', [Nick, "N Title"], State2),
			lists:foreach(fun({xmlelement, "item", _, _} = El) ->
					      case {xml:get_tag_attr("jid", El),
						    xml:get_tag_attr("name", El)} of
						  {{value, JID}, false} ->
						      Channel = jid_to_channel(jlib:string_to_jid(JID), State2),
						      send_reply('RPL_LIST', [Nick, Channel, "0", ""], State2);
						  {{value, JID}, {value, Name}} ->
						      Channel = jid_to_channel(jlib:string_to_jid(JID), State2),
						      send_reply('RPL_LIST', [Nick, Channel, "0", Name], State2);
						  _ -> ok
					      end
				      end, Items),
			send_reply('RPL_LISTEND', [Nick, "End of discovery result"], State2);
		    _ ->
			send_reply('ERR_NOSUCHSERVER', ["Invalid response"], State2)
		end,
		{next_state, wait_for_cmd, State2}
	end,
    NewState = State#state{outgoing_requests = ?DICT:append(Id, F, State#state.outgoing_requests)},
    {next_state, wait_for_cmd, NewState};

wait_for_cmd({line, #line{command = "WHO", params = [[$# | Channel1] = Channel]}},
	     #state{nick = MyNick} = State) ->
    case ?DICT:find(Channel, State#state.seen) of
	{ok, ChannelSeen} ->
	    ?DICT:fold(fun(Nick, #seen{show = Show, role = Role}, _) ->
			       Away = case Show of
					  "" -> false;
					  "chat" -> false;
					  _ -> true
				      end,
			       Flags =
				   if
				       Away -> "G";
				       true -> "H"
				   end ++
				   case Role of
				       "moderator" -> "@";
				       "participant" -> "+";
				       _ -> ""
				   end,
			       JID = channel_nick_to_jid(Nick, Channel, State),
			       %% "<channel> <user> <host> <server> <nick> <H|G>[*][@|+] :<hopcount> <real name>"
			       send_reply('RPL_WHOREPLY', [MyNick,
							   Channel,
							   JID#jid.resource,
							   Channel1,
							   JID#jid.server,
							   Nick,
							   Flags,
							   "0 " ++ Nick], State)
		       end, ok, ChannelSeen),
	    send_reply('RPL_ENDOFWHO', ["End of /WHO list"], State);
	error ->
	    send_reply('ERR_CANNOTSENDTOCHAN', [Channel, "Cannot send to channel"], State)
    end,
    {next_state, wait_for_cmd, State};

wait_for_cmd({line, #line{command = "AWAY", params = []}}, #state{nick = Nick} = State) ->
    Packet =
	{xmlelement, "presence", [], []},
    From = user_jid(State),
    foreach_channel(fun(Room, _) ->
			    ejabberd_router:route(From, Room, Packet)
		    end, State),
    send_reply('RPL_UNAWAY', [Nick, "Presence sent"], State),
    {next_state, wait_for_cmd, State};

wait_for_cmd({line, #line{command = "AWAY", params = [AwayMsg]}}, #state{nick = Nick} = State) ->
    Packet =
	{xmlelement, "presence", [],
	 [
	  {xmlelement, "show", [],
	   [{xmlcdata, "away"}]},
	  {xmlelement, "status", [],
	   [{xmlcdata, AwayMsg}]}
	 ]},
    From = user_jid(State),
    foreach_channel(fun(Room, _) ->
			    ejabberd_router:route(From, Room, Packet)
		    end, State),
    send_reply('RPL_NOWAWAY', [Nick, "Presence sent: " ++ AwayMsg], State),
    {next_state, wait_for_cmd, State};

wait_for_cmd({line, #line{command = "QUIT", params = [QuitMsg]}}, State) ->
    {stop, normal, State#state{quit_msg = QuitMsg}};

wait_for_cmd({line, #line{command = Unknown, params = Params} = Line}, State) ->
    ?INFO_MSG("Unknown command: ~p", [Line]),
    send_reply('ERR_UNKNOWNCOMMAND', [Unknown, "Unknown command or arity: " ++
				      Unknown ++ "/" ++ integer_to_list(length(Params))], State),
    {next_state, wait_for_cmd, State};

wait_for_cmd({route, From, _To, {xmlelement, "presence", Attrs, Els} = El}, State) ->
    Type = xml:get_attr_s("type", Attrs),
    FromRoom = jlib:jid_remove_resource(From),
    FromNick = From#jid.resource,

    Status = xml:get_path_s(El, [{elem, "status"}, cdata]),
    Show = xml:get_path_s(El, [{elem, "show"}, cdata]),
    Role = case find_el("x", ?NS_MUC_USER, Els) of
	       nothing ->
		   "";
	       XMucEl ->
		   xml:get_path_s(XMucEl, [{elem, "item"}, {attr, "role"}])
	   end,

    Channel = jid_to_channel(From, State),
    MyNick = State#state.nick,
    IRCSender = make_irc_sender(FromNick, FromRoom, State),

    Joining = ?DICT:find(FromRoom, State#state.joining),
    Joined = ?DICT:find(FromRoom, State#state.joined),
    case {Joining, Joined, Type} of
	{{ok, BufferedNicks}, _, ""} ->
	    case BufferedNicks of
		[] ->
		    %% If this is the first presence, tell the
		    %% client that it's joining.
		    send_command(make_irc_sender(MyNick, FromRoom, State),
				 "JOIN", [Channel], State);
		_ ->
		    ok
	    end,

	    NewBufferedNicks = [{FromNick, Role} | BufferedNicks],
	    ?DEBUG("~s is present in ~s.  we now have ~p.",
		   [FromNick, Channel, NewBufferedNicks]),
	    NewSeen = update_seen(Channel,
				  fun(D) ->
					  ?DICT:store(FromNick,
						      #seen{status = Status, show = Show,
							    role = Role},
						      D)
				  end, State#state.seen),
	    %% We receive our own presence last.  XXX: there
	    %% are some status codes here.  See XEP-0045,
	    %% section 7.1.3.
	    NewState =
		case FromNick of
		    MyNick ->
			send_reply('RPL_NAMREPLY',
				   [MyNick, "=",
				    Channel,
				    lists:append(
				      lists:map(
					fun({Nick, Role1}) ->
						case Role1 of
						    "moderator" ->
							"@";
						    "participant" ->
							"+";
						    _ ->
							""
						end ++ Nick ++ " "
					end, NewBufferedNicks))],
				   State),
			send_reply('RPL_ENDOFNAMES',
				   [Channel,
				    "End of /NAMES list"],
				   State),
			NewJoiningDict = ?DICT:erase(FromRoom, State#state.joining),
			ChannelData = #channel{participants = NewBufferedNicks},
			NewJoinedDict = ?DICT:store(FromRoom, ChannelData, State#state.joined),
			State#state{joining = NewJoiningDict,
				    joined = NewJoinedDict,
				    seen = NewSeen};
		    _ ->
			NewJoining = ?DICT:store(FromRoom, NewBufferedNicks, State#state.joining),
			State#state{joining = NewJoining,
				    seen = NewSeen}
		end,
	    {next_state, wait_for_cmd, NewState};
	{{ok, _BufferedNicks}, _, "error"} ->
	    NewState =
		case FromNick of
		    MyNick ->
			%% we couldn't join the room
			{ReplyCode, ErrorDescription} =
			    case xml:get_subtag(El, "error") of
				{xmlelement, _, _, _} = ErrorEl ->
				    {ErrorName, ErrorText} = parse_error(ErrorEl),
				    {case ErrorName of
					 "forbidden" -> 'ERR_INVITEONLYCHAN';
					 _ -> 'ERR_NOSUCHCHANNEL'
				     end,
				     if is_list(ErrorText) ->
					     ErrorName ++ ": " ++ ErrorText;
					true ->
					     ErrorName
				     end};
				_ ->
				    {'ERR_NOSUCHCHANNEL', "Unknown error"}
			    end,
			send_reply(ReplyCode, [Channel, ErrorDescription], State),

			NewJoiningDict = ?DICT:erase(FromRoom, State#state.joining),
			NewSeen = update_seen(Channel,
					      fun(D) ->
						      ?DICT:erase(FromNick, D)
					      end, State#state.seen),
			State#state{joining = NewJoiningDict, seen = NewSeen};
		    _ ->
			?ERROR_MSG("ignoring presence of type ~s from ~s while joining room",
				   [Type, jlib:jid_to_string(From)]),
			State
		end,
	    {next_state, wait_for_cmd, NewState};
	%% Presence in a channel we have already joined
	{_, {ok, _}, ""} ->
	    %% Someone enters
	    case get_seen(Channel, FromNick, State#state.seen) of
		{ok, _Seen} ->
		    ignore;
		error ->
		    send_command(IRCSender, "JOIN", [Channel], State)
	    end,
	    NewSeen = update_seen(Channel,
				  fun(D) ->
					  ?DICT:store(FromNick,
						      #seen{status = Status, show = Show,
							    role = Role},
						      D)
				  end, State#state.seen),
	    {next_state, wait_for_cmd, State#state{seen = NewSeen}};
	{_, {ok, _}, _} ->
	    %% Someone leaves
	    case get_seen(Channel, FromNick, State#state.seen) of
		{ok, _Seen} ->
		    NewSeen = update_seen(Channel,
					  fun(D) ->
						  ?DICT:erase(FromNick, D)
					  end, State#state.seen),
		    PartMsg = if
				  is_list(Status) -> remove_line_breaks(Status);
				  true -> ""
			      end,
		    send_command(IRCSender, "PART", [Channel, PartMsg], State),
		    {next_state, wait_for_cmd, State#state{seen = NewSeen}};
		error ->
		    ignore
	    end;
	_ ->
	    ?INFO_MSG("unexpected presence from ~s", [jlib:jid_to_string(From)]),
	    {next_state, wait_for_cmd, State}
    end;

wait_for_cmd({route, From, _To, {xmlelement, "message", Attrs, Els} = El}, State) ->
    Type = xml:get_attr_s("type", Attrs),
    case Type of
	"groupchat" ->
	    ChannelJID = jlib:jid_remove_resource(From),
	    case ?DICT:find(ChannelJID, State#state.joined) of
		{ok, #channel{} = ChannelData} ->
		    FromChannel = jid_to_channel(From, State),
		    FromNick = From#jid.resource,
		    Subject = xml:get_path_s(El, [{elem, "subject"}, cdata]),
		    Body = xml:get_path_s(El, [{elem, "body"}, cdata]),
		    XDelay = lists:any(fun({xmlelement, "x", XAttrs, _}) ->
					       xml:get_attr_s("xmlns", XAttrs) == ?NS_DELAY;
					  (_) ->
					       false
				       end, Els),
		    if
			Subject /= "" ->
			    CleanSubject = lists:map(fun($\n) ->
							     $\ ;
							(C) -> C
						     end, Subject),
			    send_text_command(make_irc_sender(From, State),
					      "TOPIC", [FromChannel, CleanSubject], State),
			    NewChannelData = ChannelData#channel{topic = CleanSubject},
			    NewState = State#state{joined = ?DICT:store(jlib:jid_remove_resource(From), NewChannelData, State#state.joined)},
			    {next_state, wait_for_cmd, NewState};
			not XDelay, FromNick == State#state.nick ->
			    %% there is no message echo in IRC.
			    %% we let the backlog through, though.
			    {next_state, wait_for_cmd, State};
			true ->
			    BodyLines = string:tokens(Body, "\n"),
			    lists:foreach(
			      fun(Line) ->
				      Line1 =
					  case Line of
					      [$/, $m, $e, $  | Action] ->
						  [1]++"ACTION "++Action++[1];
					      _ ->
						  Line
					  end,
				      send_text_command(make_irc_sender(From, State),
							"PRIVMSG", [FromChannel, Line1], State)
			      end, BodyLines),
			    {next_state, wait_for_cmd, State}
		    end;
		error ->
		    ?ERROR_MSG("got message from ~s without having joined it",
			       [jlib:jid_to_string(ChannelJID)]),
		    {next_state, wait_for_cmd, State}
	    end;
	"error" ->
	    MucHost = State#state.muc_host,
	    ErrorFrom =
		case From of
		    #jid{lserver = MucHost,
			 luser = Room,
			 lresource = ""} ->
			[$#|Room];
		    #jid{lserver = MucHost,
			 luser = Room,
			 lresource = Nick} ->
			Nick++"#"++Room;
		    #jid{} ->
			%% ???
			jlib:jid_to_string(From)
		end,
	    %% I think this should cover all possible combinations of
	    %% XMPP and non-XMPP error messages...
	    ErrorText =
		error_to_string(xml:get_subtag(El, "error")),
	    send_text_command("", "NOTICE", [State#state.nick,
					     "Message to "++ErrorFrom++" bounced: "++
					     ErrorText], State),
	    {next_state, wait_for_cmd, State};
	_ ->
	    ChannelJID = jlib:jid_remove_resource(From),
	    case ?DICT:find(ChannelJID, State#state.joined) of
		{ok, #channel{}} ->
		    FromNick = From#jid.lresource++jid_to_channel(From, State),
		    Body = xml:get_path_s(El, [{elem, "body"}, cdata]),
		    BodyLines = string:tokens(Body, "\n"),
		    lists:foreach(
		      fun(Line) ->
			      Line1 =
				  case Line of
				      [$/, $m, $e, $  | Action] ->
					  [1]++"ACTION "++Action++[1];
				      _ ->
					  Line
				  end,
			      send_text_command(FromNick, "PRIVMSG", [State#state.nick, Line1], State)
		      end, BodyLines),
		    {next_state, wait_for_cmd, State};
	       _ ->
		    ?INFO_MSG("unexpected message from ~s", [jlib:jid_to_string(From)]),
		    {next_state, wait_for_cmd, State}
	    end
    end;

wait_for_cmd({route, From, To, {xmlelement, "iq", Attrs, _} = El},
	     #state{outgoing_requests = OutgoingRequests} = State) ->
    Type = xml:get_attr_s("type", Attrs),
    Id = xml:get_attr_s("id", Attrs),
    case ?DICT:find(Id, OutgoingRequests) of
	{ok, [F]} when Type == "result"; Type == "error" ->
	    NewState = State#state{outgoing_requests = ?DICT:erase(Id, OutgoingRequests)},
	    F(El, NewState);
	_ when Type == "get"; Type == "set" ->
	    ejabberd_router:route(To, From,
				  jlib:make_error_reply(El, ?ERR_FEATURE_NOT_IMPLEMENTED)),
	    {next_state, wait_for_cmd, State}
    end;

wait_for_cmd(Event, State) ->
    ?INFO_MSG("unexpected event ~p", [Event]),
    {next_state, wait_for_cmd, State}.

join_channels([], _, State) ->
    State;
join_channels(Channels, [], State) ->
    join_channels(Channels, [none], State);
join_channels([Channel | Channels], [Key | Keys],
	      #state{nick = Nick} = State) ->
    Packet =
	{xmlelement, "presence", [],
	 [{xmlelement, "x", [{"xmlns", ?NS_MUC}],
	   case Key of
	       none ->
		   [];
	       _ ->
		   [{xmlelement, "password", [], filter_cdata(Key)}]
	   end}]},
    From = user_jid(State),
    To = channel_nick_to_jid(Nick, Channel, State),
    Room = jlib:jid_remove_resource(To),
    ejabberd_router:route(From, To, Packet),
    NewState = State#state{joining = ?DICT:store(Room, [], State#state.joining)},
    join_channels(Channels, Keys, NewState).

part_channels([], State, _Message) ->
    State;
part_channels([Channel | Channels], State, Message) ->
    Packet =
	{xmlelement, "presence",
	 [{"type", "unavailable"}],
	 case Message of
	    nothing -> [];
	    _ -> [{xmlelement, "status", [],
		  [{xmlcdata, Message}]}]
	 end},
    From = user_jid(State),
    To = channel_nick_to_jid(State#state.nick, Channel, State),
    ejabberd_router:route(From, To, Packet),
    RoomJID = channel_to_jid(Channel, State),
    NewState = State#state{joined = ?DICT:erase(RoomJID, State#state.joined)},
    part_channels(Channels, NewState, Message).

parse_line(Line) ->
    {Line1, LastParam} =
	case string:str(Line, " :") of
	    0 ->
		{Line, []};
	    Index ->
		{string:substr(Line, 1, Index - 1),
		 [string:substr(Line, Index + 2) -- "\r\n"]}
	end,
    Tokens = string:tokens(Line1, " \r\n"),
    {Prefix, Tokens1} =
	case Line1 of
	    [$: | _] ->
		{hd(Tokens), tl(Tokens)};
	    _ ->
		{none, Tokens}
	end,
    [Command | Params] = Tokens1,
    UCCommand = upcase(Command),
    #line{prefix = Prefix, command = UCCommand, params = Params ++ LastParam}.

upcase([]) ->
    [];
upcase([C|String]) ->
    [if $a =< C, C =< $z ->
	     C - ($a - $A);
	true ->
	     C
     end | upcase(String)].

%% sender

send_line(Line, #state{sockmod = SockMod, socket = Socket, encoding = Encoding}) ->
    ?DEBUG("sending ~s", [Line]),
    gen_tcp = SockMod,
    EncodedLine = iconv:convert("utf-8", Encoding, Line),
    ok = gen_tcp:send(Socket, [EncodedLine, 13, 10]).

send_command(Sender, Command, Params, State) ->
    send_command(Sender, Command, Params, State, false).

%% Some IRC software require commands with text to have the text
%% quoted, even it's not if not necessary.
send_text_command(Sender, Command, Params, State) ->
    send_command(Sender, Command, Params, State, true).

send_command(Sender, Command, Params, State, AlwaysQuote) ->
    Prefix = case Sender of
		 "" ->
		     [$: | State#state.host];
		 _ ->
		     [$: | Sender]
	     end,
    ParamString = make_param_string(Params, AlwaysQuote),
    send_line(Prefix ++ " " ++ Command ++ ParamString, State).

send_reply(Reply, Params, State) ->
    Number = case Reply of
		 'ERR_UNKNOWNCOMMAND' ->
		     "421";
		 'ERR_ERRONEUSNICKNAME' ->
		     "432";
		 'ERR_NICKCOLLISION' ->
		     "436";
		 'ERR_NOTONCHANNEL' ->
		     "442";
		 'ERR_NOCHANMODES' ->
		     "477";
		 'ERR_UMODEUNKNOWNFLAG' ->
		     "501";
		 'ERR_USERSDONTMATCH' ->
		     "502";
		 'ERR_NOSUCHCHANNEL' ->
		     "403";
		 'ERR_INVITEONLYCHAN' ->
		     "473";
		 'ERR_NOSUCHSERVER' ->
		     "402";
		 'ERR_CANNOTSENDTOCHAN' ->
		     "404";
		 'RPL_UMODEIS' ->
		     "221";
		 'RPL_CHANNELMODEIS' ->
		     "324";
		 'RPL_NAMREPLY' ->
		     "353";
		 'RPL_ENDOFNAMES' ->
		     "366";
		 'RPL_BANLIST' ->
		     "367";
		 'RPL_ENDOFBANLIST' ->
		     "368";
		 'RPL_NOTOPIC' ->
		     "331";
		 'RPL_TOPIC' ->
		     "332";
		 'RPL_MOTD' ->
		     "372";
		 'RPL_MOTDSTART' ->
		     "375";
		 'RPL_ENDOFMOTD' ->
		     "376";
		 'RPL_LISTSTART' ->
		     "321";
		 'RPL_LIST' ->
		     "322";
		 'RPL_LISTEND' ->
		     "323";
		 'RPL_WHOREPLY' ->
		     "352";
		 'RPL_ENDOFWHO' ->
		     "315";
		 'RPL_NOWAWAY' ->
		     "306";
		 'RPL_UNAWAY' ->
		     "305"
	     end,
    send_text_command("", Number, Params, State).

make_param_string([], _) -> "";
make_param_string([LastParam], AlwaysQuote) ->
    case {AlwaysQuote, LastParam, lists:member($\ , LastParam)} of
	{true, _, _} ->
	    " :" ++ LastParam;
	{_, _, true} ->
	    " :" ++ LastParam;
	{_, [$:|_], _} ->
	    " :" ++ LastParam;
	{_, _, _} ->
	    " " ++ LastParam
    end;
make_param_string([Param | Params], AlwaysQuote) ->
?ERROR_MSG("make_param_string(~p, ~p)~n", [[Param | Params], AlwaysQuote]),
    case lists:member($\ , Param) of
	false ->
	    " " ++ Param ++ make_param_string(Params, AlwaysQuote);
	true ->
	    SafeParam = lists:map(fun($ ) -> $_;
				     (C) -> C
				  end, Param),
	    " " ++ SafeParam ++ make_param_string(Params, AlwaysQuote)
    end.

find_el(Name, NS, [{xmlelement, N, Attrs, _} = El|Els]) ->
    XMLNS = xml:get_attr_s("xmlns", Attrs),
    case {Name, NS} of
	{N, XMLNS} ->
	    El;
	_ ->
	    find_el(Name, NS, Els)
    end;
find_el(_, _, []) ->
    nothing.

update_seen(Channel, F, Seen) ->
    OldChannelSeen =
	case ?DICT:find(Channel, Seen) of
	    {ok, D} -> D;
	    error -> ?DICT:new()
	end,
    NewChannelSeen = F(OldChannelSeen),
    case ?DICT:size(NewChannelSeen) of
	0 ->
	    ?DICT:erase(Channel, Seen);
	_ ->
	    ?DICT:store(Channel, NewChannelSeen, Seen)
    end.

get_seen(Channel, Nick, Seen) ->
    case ?DICT:find(Channel, Seen) of
	{ok, ChannelSeen} ->
	    ?DICT:find(Nick, ChannelSeen);
	error ->
	    error
    end.

foreach_channel(F, #state{joined = Joined, joining = Joining}) ->
    ?DICT:map(F, Joined),
    ?DICT:map(F, Joining).

channel_to_jid([$#|Channel], State) ->
    channel_to_jid(Channel, State);
channel_to_jid(Channel, #state{muc_host = MucHost,
			       channels_to_jids = ChannelsToJids}) ->
    case ?DICT:find(Channel, ChannelsToJids) of
	{ok, RoomJID} -> RoomJID;
	_ -> jlib:make_jid(Channel, MucHost, "")
    end.

channel_nick_to_jid(Nick, [$#|Channel], State) ->
    channel_nick_to_jid(Nick, Channel, State);
channel_nick_to_jid(Nick, Channel, #state{muc_host = MucHost,
					 channels_to_jids = ChannelsToJids}) ->
    case ?DICT:find(Channel, ChannelsToJids) of
	{ok, RoomJID} -> jlib:jid_replace_resource(RoomJID, Nick);
	_ -> jlib:make_jid(Channel, MucHost, Nick)
    end.

jid_to_channel(#jid{user = Room} = RoomJID,
	       #state{jids_to_channels = JidsToChannels}) ->
    case ?DICT:find(jlib:jid_remove_resource(RoomJID), JidsToChannels) of
	{ok, Channel} -> [$#|Channel];
	_ -> [$#|Room]
    end.

make_irc_sender(Nick, #jid{luser = Room} = RoomJID,
		#state{jids_to_channels = JidsToChannels}) ->
    Safe = fun(S) ->
		   [C || C <- S,
			 C > $\ ]
	   end,
    SafeNick = Safe(Nick),
    case ?DICT:find(jlib:jid_remove_resource(RoomJID), JidsToChannels) of
	{ok, Channel} -> SafeNick++"!"++SafeNick++"@"++Safe(Channel);
	_ -> SafeNick++"!"++SafeNick++"@"++Safe(Room)
    end.
make_irc_sender(#jid{lresource = Nick} = JID, State) ->
    make_irc_sender(Nick, JID, State).

user_jid(#state{user = User, host = Host, realname = Realname}) ->
    jlib:make_jid(User, Host, Realname).

filter_cdata(Msg) ->
    [{xmlcdata, filter_message(Msg)}].

filter_message(Msg) ->
    lists:filter(
      fun(C) ->
	      if (C < 32) and
		 (C /= 9) and
		 (C /= 10) and
		 (C /= 13) ->
		      false;
		 true -> true
	      end
      end, Msg).

translate_action(Msg) ->
    case Msg of
	[1, $A, $C, $T, $I, $O, $N, $  | Action] ->
	    "/me "++Action;
	_ ->
	    Msg
    end.

remove_line_breaks(S) ->
    lists:map(fun($\r) ->
		      $ ;
		 ($\n) ->
		      $ ;
		 (C) ->
		      C
	      end, S).

parse_error({xmlelement, "error", _ErrorAttrs, ErrorEls} = ErrorEl) ->
    ErrorTextEl = xml:get_subtag(ErrorEl, "text"),
    ErrorName =
	case ErrorEls -- [ErrorTextEl] of
	    [{xmlelement, ErrorReason, _, _}] ->
		ErrorReason;
	    _ ->
		"unknown error"
	end,
    ErrorText =
	case ErrorTextEl of
	    {xmlelement, _, _, _} ->
		xml:get_tag_cdata(ErrorTextEl);
	    _ ->
		nothing
    end,
    {ErrorName, ErrorText}.

error_to_string({xmlelement, "error", _ErrorAttrs, _ErrorEls} = ErrorEl) ->
    case parse_error(ErrorEl) of
	{ErrorName, ErrorText} when is_list(ErrorText) ->
	    ErrorName ++ ": " ++ ErrorText;
	{ErrorName, _} ->
	    ErrorName
    end;
error_to_string(_) ->
    "unknown error".
