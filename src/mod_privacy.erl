%%%----------------------------------------------------------------------
%%% File    : mod_privacy.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : jabber:iq:privacy support
%%% Created : 21 Jul 2003 by Alexey Shchepin <alexey@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2008   Process-one
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%                         
%%% You should have received a copy of the GNU General Public License
%%% along with this program; if not, write to the Free Software
%%% Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA
%%% 02111-1307 USA
%%%
%%%----------------------------------------------------------------------

-module(mod_privacy).
-author('alexey@process-one.net').

-behaviour(gen_mod).

-export([start/2, stop/1,
	 process_iq/3,
	 process_iq_set/4,
	 process_iq_get/5,
	 get_user_list/3,
	 check_packet/6,
	 updated_list/3]).

-include("ejabberd.hrl").
-include("jlib.hrl").
-include("mod_privacy.hrl").


start(Host, Opts) ->
    IQDisc = gen_mod:get_opt(iqdisc, Opts, one_queue),
    mnesia:create_table(privacy, [{disc_copies, [node()]},
				  {attributes, record_info(fields, privacy)}]),
    update_table(),
    ejabberd_hooks:add(privacy_iq_get, Host,
		       ?MODULE, process_iq_get, 50),
    ejabberd_hooks:add(privacy_iq_set, Host,
		       ?MODULE, process_iq_set, 50),
    ejabberd_hooks:add(privacy_get_user_list, Host,
		       ?MODULE, get_user_list, 50),
    ejabberd_hooks:add(privacy_check_packet, Host,
		       ?MODULE, check_packet, 50),
    ejabberd_hooks:add(privacy_updated_list, Host,
		       ?MODULE, updated_list, 50),
    gen_iq_handler:add_iq_handler(ejabberd_sm, Host, ?NS_PRIVACY,
				  ?MODULE, process_iq, IQDisc),
    gen_iq_handler:add_iq_handler(ejabberd_sm, Host, ?NS_BLOCKING,
				  ?MODULE, process_iq, IQDisc).

stop(Host) ->
    ejabberd_hooks:delete(privacy_iq_get, Host,
			  ?MODULE, process_iq_get, 50),
    ejabberd_hooks:delete(privacy_iq_set, Host,
			  ?MODULE, process_iq_set, 50),
    ejabberd_hooks:delete(privacy_get_user_list, Host,
			  ?MODULE, get_user_list, 50),
    ejabberd_hooks:delete(privacy_check_packet, Host,
			  ?MODULE, check_packet, 50),
    ejabberd_hooks:delete(privacy_updated_list, Host,
			  ?MODULE, updated_list, 50),
    gen_iq_handler:remove_iq_handler(ejabberd_sm, Host, ?NS_PRIVACY),
    gen_iq_handler:remove_iq_handler(ejabberd_sm, Host, ?NS_BLOCKING).

process_iq(_From, _To, IQ) ->
    SubEl = IQ#iq.sub_el,
    IQ#iq{type = error, sub_el = [SubEl, ?ERR_NOT_ALLOWED]}.


process_iq_get(_, From, _To,
	       #iq{xmlns = ?NS_PRIVACY,
		   sub_el = {xmlelement, "query", _, Els}},
	       #userlist{name = Active}) ->
    #jid{luser = LUser, lserver = LServer} = From,
    case xml:remove_cdata(Els) of
	[] ->
	    process_lists_get(LUser, LServer, Active);
	[{xmlelement, Name, Attrs, _SubEls}] ->
	    case Name of
		"list" ->
		    ListName = xml:get_attr("name", Attrs),
		    process_list_get(LUser, LServer, ListName);
		_ ->
		    {error, ?ERR_BAD_REQUEST}
	    end;
	_ ->
	    {error, ?ERR_BAD_REQUEST}
    end;

process_iq_get(_, From, _To,
	       #iq{xmlns = ?NS_BLOCKING,
		   sub_el = {xmlelement, "blocklist", _, _}},
	       _) ->
    #jid{luser = LUser, lserver = LServer} = From,
    process_blocklist_get(LUser, LServer).


process_lists_get(LUser, LServer, Active) ->
    case catch mnesia:dirty_read(privacy, {LUser, LServer}) of
	{'EXIT', _Reason} ->
	    {error, ?ERR_INTERNAL_SERVER_ERROR};
	[] ->
	    {result, [{xmlelement, "query", [{"xmlns", ?NS_PRIVACY}], []}]};
	[#privacy{default = Default, lists = Lists}] ->
	    case Lists of
		[] ->
		    {result, [{xmlelement, "query",
			       [{"xmlns", ?NS_PRIVACY}], []}]};
		_ ->
		    LItems = lists:map(
			       fun({N, _}) ->
				       {xmlelement, "list",
					[{"name", N}], []}
			       end, Lists),
		    DItems =
			case Default of
			    none ->
				LItems;
			    _ ->
				[{xmlelement, "default",
				  [{"name", Default}], []} | LItems]
			end,
		    ADItems =
			case Active of
			    none ->
				DItems;
			    _ ->
				[{xmlelement, "active",
				  [{"name", Active}], []} | DItems]
			end,
		    {result,
		     [{xmlelement, "query", [{"xmlns", ?NS_PRIVACY}],
		       ADItems}]}
	    end
    end.


process_list_get(LUser, LServer, {value, Name}) ->
    case catch mnesia:dirty_read(privacy, {LUser, LServer}) of
	{'EXIT', _Reason} ->
	    {error, ?ERR_INTERNAL_SERVER_ERROR};
	[] ->
	    {error, ?ERR_ITEM_NOT_FOUND};
	    %{result, [{xmlelement, "query", [{"xmlns", ?NS_PRIVACY}], []}]};
	[#privacy{lists = Lists}] ->
	    case lists:keysearch(Name, 1, Lists) of
		{value, {_, List}} ->
		    LItems = lists:map(fun item_to_xml/1, List),
		    {result,
		     [{xmlelement, "query", [{"xmlns", ?NS_PRIVACY}],
		       [{xmlelement, "list",
			 [{"name", Name}], LItems}]}]};
		_ ->
		    {error, ?ERR_ITEM_NOT_FOUND}
	    end
    end;

process_list_get(_LUser, _LServer, false) ->
    {error, ?ERR_BAD_REQUEST}.

item_to_xml(Item) ->
    Attrs1 = [{"action", action_to_list(Item#listitem.action)},
	      {"order", order_to_list(Item#listitem.order)}],
    Attrs2 = case Item#listitem.type of
		 none ->
		     Attrs1;
		 Type ->
		     [{"type", type_to_list(Item#listitem.type)},
		      {"value", value_to_list(Type, Item#listitem.value)} |
		      Attrs1]
	     end,
    SubEls = case Item#listitem.match_all of
		 true ->
		     [];
		 false ->
		     SE1 = case Item#listitem.match_iq of
			       true ->
				   [{xmlelement, "iq", [], []}];
			       false ->
				   []
			   end,
		     SE2 = case Item#listitem.match_message of
			       true ->
				   [{xmlelement, "message", [], []} | SE1];
			       false ->
				   SE1
			   end,
		     SE3 = case Item#listitem.match_presence_in of
			       true ->
				   [{xmlelement, "presence-in", [], []} | SE2];
			       false ->
				   SE2
			   end,
		     SE4 = case Item#listitem.match_presence_out of
			       true ->
				   [{xmlelement, "presence-out", [], []} | SE3];
			       false ->
				   SE3
			   end,
		     SE4
	     end,
    {xmlelement, "item", Attrs2, SubEls}.


action_to_list(Action) ->
    case Action of
	allow -> "allow";
	deny -> "deny"
    end.

order_to_list(Order) ->
    integer_to_list(Order).

type_to_list(Type) ->
    case Type of
	jid -> "jid";
	group -> "group";
	subscription -> "subscription"
    end.

value_to_list(Type, Val) ->
    case Type of
	jid -> jlib:jid_to_string(Val);
	group -> Val;
	subscription ->
	    case Val of
		both -> "both";
		to -> "to";
		from -> "from";
		none -> "none"
	    end
    end.



list_to_action(S) ->
    case S of
	"allow" -> allow;
	"deny" -> deny
    end.


process_blocklist_get(LUser, LServer) ->
    case catch mnesia:dirty_read(privacy, {LUser, LServer}) of
	{'EXIT', _Reason} ->
	    {error, ?ERR_INTERNAL_SERVER_ERROR};
	[] ->
	    {result, [{xmlelement, "blocklist", [{"xmlns", ?NS_BLOCKING}], []}]};
	[#privacy{default = Default, lists = Lists}] ->
	    case lists:keysearch(Default, 1, Lists) of
		{value, {_, List}} ->
		    JIDs = list_to_blocklist_jids(List, []),
		    Items = lists:map(
			      fun(JID) ->
				      ?DEBUG("JID: ~p",[JID]),
				      {xmlelement, "item",
				       [{"jid", jlib:jid_to_string(JID)}], []}
			      end, JIDs),
		    {result,
		     [{xmlelement, "blocklist", [{"xmlns", ?NS_BLOCKING}],
		       Items}]};
		_ ->
		    {result, [{xmlelement, "blocklist", [{"xmlns", ?NS_BLOCKING}], []}]}
	    end
    end.


process_iq_set(_, From, _To, #iq{xmlns = ?NS_PRIVACY,
				 sub_el = {xmlelement, "query", _, Els}}) ->
    #jid{luser = LUser, lserver = LServer} = From,
    case xml:remove_cdata(Els) of
	[{xmlelement, Name, Attrs, SubEls}] ->
	    ListName = xml:get_attr("name", Attrs),
	    case Name of
		"list" ->
		    process_list_set(LUser, LServer, ListName,
				     xml:remove_cdata(SubEls));
		"active" ->
		    process_active_set(LUser, LServer, ListName);
		"default" ->
		    process_default_set(LUser, LServer, ListName);
		_ ->
		    {error, ?ERR_BAD_REQUEST}
	    end;
	_ ->
	    {error, ?ERR_BAD_REQUEST}
    end;

process_iq_set(_, From, _To, #iq{xmlns = ?NS_BLOCKING,
				 sub_el = {xmlelement, SubElName, _, SubEls}}) ->
    #jid{luser = LUser, lserver = LServer} = From,
    case {SubElName, xml:remove_cdata(SubEls)} of
	{"block", []} ->
	    {error, ?ERR_BAD_REQUEST};
	{"block", Els} ->
	    JIDs = parse_blocklist_items(Els, []),
	    process_blocklist_block(LUser, LServer, JIDs);
	{"unblock", []} ->
	    process_blocklist_unblock_all(LUser, LServer);
	{"unblock", Els} ->
	    JIDs = parse_blocklist_items(Els, []),
	    process_blocklist_unblock(LUser, LServer, JIDs);
	_ ->
	    {error, ?ERR_BAD_REQUEST}
    end.

process_default_set(LUser, LServer, {value, Name}) ->
    F = fun() ->
		case mnesia:read({privacy, {LUser, LServer}}) of
		    [] ->
			{error, ?ERR_ITEM_NOT_FOUND};
		    [#privacy{lists = Lists} = P] ->
			case lists:keymember(Name, 1, Lists) of
			    true ->
				mnesia:write(P#privacy{default = Name,
						       lists = Lists}),
				{result, []};
			    false ->
				{error, ?ERR_ITEM_NOT_FOUND}
			end
		end
	end,
    case mnesia:transaction(F) of
	{atomic, {error, _} = Error} ->
	    Error;
	{atomic, {result, _} = Res} ->
	    Res;
	_ ->
	    {error, ?ERR_INTERNAL_SERVER_ERROR}
    end;

process_default_set(LUser, LServer, false) ->
    F = fun() ->
		case mnesia:read({privacy, {LUser, LServer}}) of
		    [] ->
			{result, []};
		    [R] ->
			mnesia:write(R#privacy{default = none}),
			{result, []}
		end
	end,
    case mnesia:transaction(F) of
	{atomic, {error, _} = Error} ->
	    Error;
	{atomic, {result, _} = Res} ->
	    Res;
	_ ->
	    {error, ?ERR_INTERNAL_SERVER_ERROR}
    end.


process_active_set(LUser, LServer, {value, Name}) ->
    case catch mnesia:dirty_read(privacy, {LUser, LServer}) of
	[] ->
	    {error, ?ERR_ITEM_NOT_FOUND};
	[#privacy{lists = Lists}] ->
	    case lists:keysearch(Name, 1, Lists) of
		{value, {_, List}} ->
		    {result, [], #userlist{name = Name, list = List}};
		false ->
		    {error, ?ERR_ITEM_NOT_FOUND}
	    end
    end;

process_active_set(_LUser, _LServer, false) ->
    {result, [], #userlist{}}.


process_list_set(LUser, LServer, {value, Name}, Els) ->
    case parse_items(Els) of
	false ->
	    {error, ?ERR_BAD_REQUEST};
	remove ->
	    F =
		fun() ->
			case mnesia:read({privacy, {LUser, LServer}}) of
			    [] ->
				{result, []};
			    [#privacy{default = Default, lists = Lists} = P] ->
				% TODO: check active
				if
				    Name == Default ->
					{error, ?ERR_CONFLICT};
				    true ->
					NewLists =
					    lists:keydelete(Name, 1, Lists),
					mnesia:write(
					  P#privacy{lists = NewLists}),
					{result, []}
				end
			end
		end,
	    case mnesia:transaction(F) of
		{atomic, {error, _} = Error} ->
		    Error;
		{atomic, {result, _} = Res} ->
		    ejabberd_router:route(
		      jlib:make_jid(LUser, LServer, ""),
		      jlib:make_jid(LUser, LServer, ""),
		      {xmlelement, "broadcast", [],
		       [{privacy_list,
			 #userlist{name = Name, list = []},
			 Name}]}),
		    Res;
		_ ->
		    {error, ?ERR_INTERNAL_SERVER_ERROR}
	    end;
	List ->
	    F =
		fun() ->
			case mnesia:wread({privacy, {LUser, LServer}}) of
			    [] ->
				NewLists = [{Name, List}],
				mnesia:write(#privacy{us = {LUser, LServer},
						      lists = NewLists}),
				{result, []};
			    [#privacy{lists = Lists} = P] ->
				NewLists1 = lists:keydelete(Name, 1, Lists),
				NewLists = [{Name, List} | NewLists1],
				mnesia:write(P#privacy{lists = NewLists}),
				{result, []}
			end
		end,
	    case mnesia:transaction(F) of
		{atomic, {error, _} = Error} ->
		    Error;
		{atomic, {result, _} = Res} ->
		    ejabberd_router:route(
		      jlib:make_jid(LUser, LServer, ""),
		      jlib:make_jid(LUser, LServer, ""),
		      {xmlelement, "broadcast", [],
		       [{privacy_list,
			 #userlist{name = Name, list = List},
			 Name}]}),
		    Res;
		_ ->
		    {error, ?ERR_INTERNAL_SERVER_ERROR}
	    end
    end;

process_list_set(_LUser, _LServer, false, _Els) ->
    {error, ?ERR_BAD_REQUEST}.


process_blocklist_block(LUser, LServer, JIDs) ->
    F =
	fun() ->
		case mnesia:wread({privacy, {LUser, LServer}}) of
		    [] ->
			% No lists yet
			P = #privacy{us = {LUser, LServer}},
			% TODO: i18n here:
			NewDefault = "Blocked contacts",
			NewLists1 = [],
			List = [];
		    [#privacy{default = Default,
			      lists = Lists} = P] ->
			case lists:keysearch(Default, 1, Lists) of
			    {value, {_, List}} ->
				% Default list exists
				NewDefault = Default,
				NewLists1 = lists:keydelete(Default, 1, Lists);
			    false ->
				% No default list yet, create one
				% TODO: i18n here:
				NewDefault = "Blocked contacts",
				NewLists1 = Lists,
				List = []
			end
		end,

		AlreadyBlocked = list_to_blocklist_jids(List, []),
		NewList =
		    lists:foldr(fun(JID, List1) ->
					case lists:member(JID, AlreadyBlocked) of
					    true ->
						List1;
					    false ->
						[#listitem{type = jid,
							   value = JID,
							   action = deny,
							   order = 0,
							   match_all = true
							  } | List1]
					end
				end, List, JIDs),
		NewLists = [{NewDefault, NewList} | NewLists1],
		mnesia:write(P#privacy{default = NewDefault,
				       lists = NewLists}),
		{result, []}
	end,
    case mnesia:transaction(F) of
	{atomic, {error, _} = Error} ->
	    Error;
	{atomic, {result, _} = Res} ->
	    % TODO: push
	    Res;
	_ ->
	    {error, ?ERR_INTERNAL_SERVER_ERROR}
    end.


process_blocklist_unblock_all(LUser, LServer) ->
    F =
	fun() ->
		case mnesia:read({privacy, {LUser, LServer}}) of
		    [] ->
			% No lists, nothing to unblock
			{result, []};
		    [#privacy{default = Default,
			      lists = Lists} = P] ->
			case lists:keysearch(Default, 1, Lists) of
			    {value, {_, List}} ->
				% Default list, remove all deny items
				NewList =
				    lists:filter(
				      fun(#listitem{action = A}) ->
					      A =/= deny
				      end, List),

				NewLists1 = lists:keydelete(Default, 1, Lists),
				NewLists = [{Default, NewList} | NewLists1],
				mnesia:write(P#privacy{lists = NewLists}),

				{result, []};
			    false ->
				% No default list, nothing to unblock
				{result, []}
			end
		end
	end,
    case mnesia:transaction(F) of
	{atomic, {error, _} = Error} ->
	    Error;
	{atomic, {result, _} = Res} ->
	    % TODO: push
	    Res;
	_ ->
	    {error, ?ERR_INTERNAL_SERVER_ERROR}
    end.


process_blocklist_unblock(LUser, LServer, JIDs) ->
    F =
	fun() ->
		case mnesia:read({privacy, {LUser, LServer}}) of
		    [] ->
			% No lists, nothing to unblock
			{result, []};
		    [#privacy{default = Default,
			      lists = Lists} = P] ->
			case lists:keysearch(Default, 1, Lists) of
			    {value, {_, List}} ->
				% Default list, remove matching deny items
				NewList =
				    lists:filter(
				      fun(#listitem{action = deny,
						    type = jid,
						    value = JID}) ->
					      not(lists:member(JID, JIDs));
					 (_) ->
					      true
				      end, List),

				NewLists1 = lists:keydelete(Default, 1, Lists),
				NewLists = [{Default, NewList} | NewLists1],
				mnesia:write(P#privacy{lists = NewLists}),

				{result, []};
			    false ->
				% No default list, nothing to unblock
				{result, []}
			end
		end
	end,
    case mnesia:transaction(F) of
	{atomic, {error, _} = Error} ->
	    Error;
	{atomic, {result, _} = Res} ->
	    % TODO: push
	    Res;
	_ ->
	    {error, ?ERR_INTERNAL_SERVER_ERROR}
    end.


parse_items([]) ->
    remove;
parse_items(Els) ->
    parse_items(Els, []).

parse_items([], Res) ->
    lists:reverse(Res);
parse_items([{xmlelement, "item", Attrs, SubEls} | Els], Res) ->
    Type   = xml:get_attr("type",   Attrs),
    Value  = xml:get_attr("value",  Attrs),
    SAction = xml:get_attr("action", Attrs),
    SOrder = xml:get_attr("order",  Attrs),
    Action = case catch list_to_action(element(2, SAction)) of
		 {'EXIT', _} -> false;
		 Val -> Val
	     end,
    Order = case catch list_to_integer(element(2, SOrder)) of
		{'EXIT', _} ->
		    false;
		IntVal ->
		    if
			IntVal >= 0 ->
			    IntVal;
			true ->
			    false
		    end
	    end,
    if
	(Action /= false) and (Order /= false) ->
	    I1 = #listitem{action = Action, order = Order},
	    I2 = case {Type, Value} of
		     {{value, T}, {value, V}} ->
			 case T of
			     "jid" ->
				 case jlib:string_to_jid(V) of
				     error ->
					 false;
				     JID ->
					 I1#listitem{
					   type = jid,
					   value = jlib:jid_tolower(JID)}
				 end;
			     "group" ->
				 I1#listitem{type = group,
					     value = V};
			     "subscription" ->
				 case V of
				     "none" ->
					 I1#listitem{type = subscription,
						     value = none};
				     "both" ->
					 I1#listitem{type = subscription,
						     value = both};
				     "from" ->
					 I1#listitem{type = subscription,
						     value = from};
				     "to" ->
					 I1#listitem{type = subscription,
						     value = to};
				     _ ->
					 false
				 end
			 end;
		     {{value, _}, false} ->
			 false;
		     _ ->
			 I1
		 end,
	    case I2 of
		false ->
		    false;
		_ ->
		    case parse_matches(I2, xml:remove_cdata(SubEls)) of
			false ->
			    false;
			I3 ->
			    parse_items(Els, [I3 | Res])
		    end
	    end;
	true ->
	    false
    end;

parse_items(_, _Res) ->
    false.


parse_matches(Item, []) ->
    Item#listitem{match_all = true};
parse_matches(Item, Els) ->
    parse_matches1(Item, Els).

parse_matches1(Item, []) ->
    Item;
parse_matches1(Item, [{xmlelement, "message", _, _} | Els]) ->
    parse_matches1(Item#listitem{match_message = true}, Els);
parse_matches1(Item, [{xmlelement, "iq", _, _} | Els]) ->
    parse_matches1(Item#listitem{match_iq = true}, Els);
parse_matches1(Item, [{xmlelement, "presence-in", _, _} | Els]) ->
    parse_matches1(Item#listitem{match_presence_in = true}, Els);
parse_matches1(Item, [{xmlelement, "presence-out", _, _} | Els]) ->
    parse_matches1(Item#listitem{match_presence_out = true}, Els);
parse_matches1(_Item, [{xmlelement, _, _, _} | _Els]) ->
    false.


list_to_blocklist_jids([], JIDs) ->
    JIDs;

list_to_blocklist_jids([#listitem{type = jid,
				  action = deny,
				  value = JID} = Item | Items], JIDs) ->
    case Item of
	#listitem{match_all = true} ->
	    Match = true;
	#listitem{match_iq = true,
		  match_message = true,
		  match_presence_in = true,
		  match_presence_out = true} ->
	    Match = true;
	_ ->
	    Match = false
    end,
    if
	Match ->
	    list_to_blocklist_jids(Items, [JID | JIDs]);
	true ->
	    list_to_blocklist_jids(Items, JIDs)
    end;

% Skip Privacy List items than cannot be mapped to Blocking items
list_to_blocklist_jids([_ | Items], JIDs) ->
    list_to_blocklist_jids(Items, JIDs).


parse_blocklist_items([], JIDs) ->
    JIDs;

parse_blocklist_items([{xmlelement, "item", Attrs, _} | Els], JIDs) ->
    case xml:get_attr("jid", Attrs) of
	{value, JID1} ->
	    JID = jlib:jid_tolower(jlib:string_to_jid(JID1)),
	    parse_blocklist_items(Els, [JID | JIDs]);
	false ->
	    % Tolerate missing jid attribute
	    parse_blocklist_items(Els, JIDs)
    end;

parse_blocklist_items([_ | Els], JIDs) ->
    % Tolerate unknown elements
    parse_blocklist_items(Els, JIDs).



get_user_list(_, User, Server) ->
    LUser = jlib:nodeprep(User),
    LServer = jlib:nameprep(Server),
    case catch mnesia:dirty_read(privacy, {LUser, LServer}) of
	[] ->
	    #userlist{};
	[#privacy{default = Default, lists = Lists}] ->
	    case Default of
		none ->
		    #userlist{};
		_ ->
		    case lists:keysearch(Default, 1, Lists) of
			{value, {_, List}} ->
			    SortedList = lists:keysort(#listitem.order, List),
			    #userlist{name = Default, list = SortedList};
			_ ->
			    #userlist{}
		    end
	    end;
	_ ->
	    #userlist{}
    end.


check_packet(_, User, Server,
	     #userlist{list = List},
	     {From, To, {xmlelement, PName, _, _}},
	     Dir) ->
    case List of
	[] ->
	    allow;
	_ ->
	    PType = case PName of
			"message" -> message;
			"iq" -> iq;
			"presence" -> presence
		    end,
	    case {PType, Dir} of
		{message, in} ->
		    LJID = jlib:jid_tolower(From),
		    {Subscription, Groups} =
			ejabberd_hooks:run_fold(
			  roster_get_jid_info, jlib:nameprep(Server),
			  {none, []}, [User, Server, LJID]),
		    check_packet_aux(List, message,
				     LJID, Subscription, Groups);
		{iq, in} ->
		    LJID = jlib:jid_tolower(From),
		    {Subscription, Groups} =
			ejabberd_hooks:run_fold(
			  roster_get_jid_info, jlib:nameprep(Server),
			  {none, []}, [User, Server, LJID]),
		    check_packet_aux(List, iq,
				     LJID, Subscription, Groups);
		{presence, in} ->
		    LJID = jlib:jid_tolower(From),
		    {Subscription, Groups} =
			ejabberd_hooks:run_fold(
			  roster_get_jid_info, jlib:nameprep(Server),
			  {none, []}, [User, Server, LJID]),
		    check_packet_aux(List, presence_in,
				     LJID, Subscription, Groups);
		{presence, out} ->
		    LJID = jlib:jid_tolower(To),
		    {Subscription, Groups} =
			ejabberd_hooks:run_fold(
			  roster_get_jid_info, jlib:nameprep(Server),
			  {none, []}, [User, Server, LJID]),
		    check_packet_aux(List, presence_out,
				     LJID, Subscription, Groups);
		_ ->
		    allow
	    end
    end.

check_packet_aux([], _PType, _JID, _Subscription, _Groups) ->
    allow;
check_packet_aux([Item | List], PType, JID, Subscription, Groups) ->
    #listitem{type = Type, value = Value, action = Action} = Item,
    case is_ptype_match(Item, PType) of
	true ->
	    case Type of
		none ->
		    Action;
		_ ->
		    case is_type_match(Type, Value,
				       JID, Subscription, Groups) of
			true ->
			    Action;
			false ->
			    check_packet_aux(List, PType,
					     JID, Subscription, Groups)
		    end
	    end;
	false ->
	    check_packet_aux(List, PType, JID, Subscription, Groups)
    end.


is_ptype_match(Item, PType) ->
    case Item#listitem.match_all of
	true ->
	    true;
	false ->
	    case PType of
		message ->
		    Item#listitem.match_message;
		iq ->
		    Item#listitem.match_iq;
		presence_in ->
		    Item#listitem.match_presence_in;
		presence_out ->
		    Item#listitem.match_presence_out
	    end
    end.


is_type_match(Type, Value, JID, Subscription, Groups) ->
    case Type of
	jid ->
	    case Value of
		{"", Server, ""} ->
		    case JID of
			{_, Server, _} ->
			    true;
			_ ->
			    false
		    end;
		{User, Server, ""} ->
		    case JID of
			{User, Server, _} ->
			    true;
			_ ->
			    false
		    end;
		_ ->
		    Value == JID
	    end;
	subscription ->
	    Value == Subscription;
	group ->
	    lists:member(Value, Groups)
    end.


updated_list(_,
	     #userlist{name = OldName} = Old,
	     #userlist{name = NewName} = New) ->
    if
	OldName == NewName ->
	    New;
	true ->
	    Old
    end.



update_table() ->
    Fields = record_info(fields, privacy),
    case mnesia:table_info(privacy, attributes) of
	Fields ->
	    ok;
	[user, default, lists] ->
	    ?INFO_MSG("Converting privacy table from "
		      "{user, default, lists} format", []),
	    Host = ?MYNAME,
	    {atomic, ok} = mnesia:create_table(
			     mod_privacy_tmp_table,
			     [{disc_only_copies, [node()]},
			      {type, bag},
			      {local_content, true},
			      {record_name, privacy},
			      {attributes, record_info(fields, privacy)}]),
	    mnesia:transform_table(privacy, ignore, Fields),
	    F1 = fun() ->
			 mnesia:write_lock_table(mod_privacy_tmp_table),
			 mnesia:foldl(
			   fun(#privacy{us = U} = R, _) ->
				   mnesia:dirty_write(
				     mod_privacy_tmp_table,
				     R#privacy{us = {U, Host}})
			   end, ok, privacy)
		 end,
	    mnesia:transaction(F1),
	    mnesia:clear_table(privacy),
	    F2 = fun() ->
			 mnesia:write_lock_table(privacy),
			 mnesia:foldl(
			   fun(R, _) ->
				   mnesia:dirty_write(R)
			   end, ok, mod_privacy_tmp_table)
		 end,
	    mnesia:transaction(F2),
	    mnesia:delete_table(mod_privacy_tmp_table);
	_ ->
	    ?INFO_MSG("Recreating privacy table", []),
	    mnesia:transform_table(privacy, ignore, Fields)
    end.


