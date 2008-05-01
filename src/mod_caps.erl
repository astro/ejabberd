%%%----------------------------------------------------------------------
%%% File    : mod_caps.erl
%%% Author  : Magnus Henoch <henoch@dtek.chalmers.se>
%%% Purpose : Request and cache Entity Capabilities (XEP-0115)
%%% Created : 7 Oct 2006 by Magnus Henoch <henoch@dtek.chalmers.se>
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

-module(mod_caps).
-author('henoch@dtek.chalmers.se').

-behaviour(gen_server).
-behaviour(gen_mod).

-export([read_caps/1,
	 note_caps/3,
	 get_features/3,
	 handle_disco_response/3]).

%% gen_mod callbacks
-export([start/2, start_link/2,
	 stop/1]).

%% gen_server callbacks
-export([init/1,
	 handle_info/2,
	 handle_call/3,
	 handle_cast/2,
	 terminate/2,
	 code_change/3
	]).

-include("ejabberd.hrl").
-include("jlib.hrl").

-define(PROCNAME, ejabberd_mod_caps).
-define(DICT, dict).

%% jid = any, node = any:    Cache entry for any valid version/hash
%% jid = JID, node = String: Cache entry for an invalid version
%%                           or deprecated caps format from a
%%                           specific jid
-record(caps, {jid, node, version, hash}).
-record(caps_features, {caps, features}).
-record(state, {host,
		disco_requests = ?DICT:new(),
		feature_queries = []}).

%% read_caps takes a list of XML elements (the child elements of a
%% <presence/> stanza) and returns an opaque value representing the
%% Entity Capabilities contained therein, or the atom nothing if no
%% capabilities are advertised.
read_caps(Els) ->
    read_caps(Els, nothing).
read_caps([{xmlelement, "c", Attrs, _Els} | Tail], Result) ->
    case xml:get_attr_s("xmlns", Attrs) of
	?NS_CAPS ->
	    Node = xml:get_attr_s("node", Attrs),
	    Version = xml:get_attr_s("ver", Attrs),
	    Hash = xml:get_attr_s("hash", Attrs),
	    read_caps(Tail, #caps{node = Node, version = Version, hash = Hash});
	_ ->
	    read_caps(Tail, Result)
    end;
read_caps([{xmlelement, "x", Attrs, _Els} | Tail], Result) ->
    case xml:get_attr_s("xmlns", Attrs) of
	?NS_MUC_USER ->
	    nothing;
	_ ->
	    read_caps(Tail, Result)
    end;
read_caps([_ | Tail], Result) ->
    read_caps(Tail, Result);
read_caps([], Result) ->
    Result.

%% note_caps should be called to make the module request disco
%% information.  Host is the host that asks, From is the full JID that
%% sent the caps packet, and Caps is what read_caps returned.
note_caps(Host, From, Caps) ->
    case Caps of
	nothing -> ok;
	_ ->
	    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
	    gen_server:cast(Proc, {note_caps, Caps#caps{jid = From}})
    end.

%% get_features returns a list of features implied by the given caps
%% record (as extracted by read_caps).  It may block, and may signal a
%% timeout error.
get_features(Host, JID, Caps) ->
    case Caps of
	nothing -> [];
	#caps{} ->
	    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
	    gen_server:call(Proc, {get_features, Caps#caps{jid = JID}})
    end.

start_link(Host, Opts) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    gen_server:start_link({local, Proc}, ?MODULE, [Host, Opts], []).

start(Host, Opts) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    ChildSpec =
	{Proc,
	 {?MODULE, start_link, [Host, Opts]},
	 transient,
	 1000,
	 worker,
	 [?MODULE]},
    supervisor:start_child(ejabberd_sup, ChildSpec).

stop(Host) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    gen_server:call(Proc, stop).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([Host, _Opts]) ->
    mnesia:create_table(caps_features,
			[{ram_copies, [node()]},
			 {attributes, record_info(fields, caps_features)}]),
    mnesia:add_table_copy(caps_features, node(), ram_copies),
    {ok, #state{host = Host}}.

maybe_get_features(Caps) ->
    F = fun() ->
		case mnesia:read({caps_features, Caps#caps{jid = any, node = any}}) of
		    [] ->
			?DEBUG("No known generic features for ~p", [Caps]),
			case mnesia:read({caps_features, Caps}) of
			    [] -> fail;
			    [#caps_features{features = Features}] -> Features
			end;
		    [#caps_features{features = Features}] ->
			Features
		end
	end,
    case mnesia:transaction(F) of
	{atomic, fail} ->
	    wait;
	{atomic, Features} ->
	    {ok, Features}
    end.

timestamp() ->
    {MegaSecs, Secs, _MicroSecs} = now(),
    MegaSecs * 1000000 + Secs.

handle_call({get_features, Caps}, From, State) ->
    case maybe_get_features(Caps) of
	{ok, Features} -> 
	    {reply, Features, State};
	wait ->
	    gen_server:cast(self(), visit_feature_queries),
	    Timeout = timestamp() + 10,
	    FeatureQueries = State#state.feature_queries,
	    NewFeatureQueries = [{From, Caps, Timeout} | FeatureQueries],
	    NewState = State#state{feature_queries = NewFeatureQueries},
	    {noreply, NewState}
    end;

handle_call(stop, _From, State) ->
    {stop, normal, ok, State}.

handle_cast({note_caps,
	     #caps{jid = From, node = Node, version = Version, hash = Hash} = Caps},
	    #state{host = Host, disco_requests = Requests} = State) ->
    ?DEBUG("note_caps ~p ~p", [Caps,State]),
    Fun = fun() ->
		  case mnesia:read({caps_features, Caps#caps{jid = any, node = any}}) of
		      [] ->
			  case mnesia:read({caps_features, Caps}) of
			      [] -> [Version];
			      _ -> []
			  end;
		      _ ->
			  []
		  end
	  end,
    case mnesia:transaction(Fun) of
	{atomic, Missing} ->
	    %% For each unknown caps "subnode", we send a disco
	    %% request.
	    NewRequests =
		lists:foldl(
		  fun(SubNode, Dict) ->
			  ID = randoms:get_string(),
			  Stanza =
			      {xmlelement, "iq",
			       [{"type", "get"},
				{"id", ID}],
			       [{xmlelement, "query",
				 [{"xmlns", ?NS_DISCO_INFO},
				  {"node", lists:concat([Node, "#", SubNode])}],
				 []}]},
			  ejabberd_local:register_iq_response_handler
			    (Host, ID, ?MODULE, handle_disco_response),
			  ejabberd_router:route(jlib:make_jid("", Host, ""), From, Stanza),
			  ?DICT:store({From, ID}, {From, SubNode, Hash}, Dict)
		  end, Requests, Missing),
	    ?DEBUG("Requests: ~p", [NewRequests]),
	    {noreply, State#state{disco_requests = NewRequests}};
	Error ->
	    ?ERROR_MSG("Transaction failed: ~p", [Error]),
	    {noreply, State}
    end;
handle_cast({disco_response, From, _To, 
	     #iq{type = Type, id = ID,
		 sub_el = SubEls}},
	    #state{disco_requests = Requests} = State) ->
    ?DEBUG("Requests: ~p", [Requests]),
    case {Type, SubEls} of
	{result, [{xmlelement, "query", _Attrs, Els} = QueryEl | _]} ->
	    case ?DICT:find({From, ID}, Requests) of
		{ok, {Node, Version, Hash}} ->
		    Features =
			lists:flatmap(fun({xmlelement, "feature", FAttrs, _}) ->
					      [xml:get_attr_s("var", FAttrs)];
					 (_) ->
					      []
				      end, Els),
		    FeaturesHash = generate_ver_from_disco_result(QueryEl, Hash),
		    ?DEBUG("Hash: ~p Version: ~p", [FeaturesHash, Version]),
		    mnesia:transaction(
		      fun() ->
			      if
				  FeaturesHash =:= Version ->
				      mnesia:write(#caps_features{caps = #caps{jid = any, node = any,
									       version = Version, hash = Hash},
								 features = Features});
				  true ->
				      mnesia:write(#caps_features{caps = #caps{jid = From, node = Node,
									       version = Version, hash = Hash},
								  features = Features})
			      end
		      end),
		    gen_server:cast(self(), visit_feature_queries);
		error ->
		    ?ERROR_MSG("ID '~s' matches no query", [ID])
	    end;
	{error, _} ->
	    %% XXX: if we get error, we cache empty feature not to probe the client continuously
	    case ?DICT:find({From, ID}, Requests) of
		{ok, {Node, Version, Hash}} ->
		    Features = [],
		    mnesia:transaction(
		      fun() ->
			      mnesia:write(#caps_features{caps = #caps{jid = From, node = Node,
								       version = Version, hash = Hash},
							  features = Features})
		      end),
		    gen_server:cast(self(), visit_feature_queries);
		error ->
		    ?ERROR_MSG("ID '~s' matches no query", [ID])
	    end,
	    gen_server:cast(self(), visit_feature_queries),
	    ?DEBUG("Error IQ reponse from ~s:~n~p", [jlib:jid_to_string(From), SubEls]);
	{result, _} ->
	    ?DEBUG("Invalid IQ contents from ~s:~n~p", [jlib:jid_to_string(From), SubEls]);
	_ ->
	    %% Can't do anything about errors
	    ok
    end,
    NewRequests = ?DICT:erase({From, ID}, Requests),
    {noreply, State#state{disco_requests = NewRequests}};
handle_cast(visit_feature_queries, #state{feature_queries = FeatureQueries} = State) ->
    Timestamp = timestamp(),
    NewFeatureQueries =
	lists:foldl(fun({From, Caps, Timeout}, Acc) ->
			    case maybe_get_features(Caps) of
				% Within timeout,
				% disco_request still running
				wait when Timeout > Timestamp -> [{From, Caps, Timeout} | Acc];
				% Timeout
				wait ->
				    Features = [],
				    gen_server:reply(From, Features),
				    Acc;
				% Disco response available
				{ok, Features} ->
				    gen_server:reply(From, Features),
				    Acc
			    end
		    end, [], FeatureQueries),
    {noreply, State#state{feature_queries = NewFeatureQueries}}.

handle_disco_response(From, To, IQ) ->
    #jid{lserver = Host} = To,
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    gen_server:cast(Proc, {disco_response, From, To, IQ}).

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% http://www.xmpp.org/extensions/xep-0115.html#ver-gen
generate_ver_from_disco_result(QueryEl, "sha-1") ->
    generate_ver_from_disco_result1(QueryEl, fun crypto:sha/1);
generate_ver_from_disco_result(QueryEl, "md5") ->
    generate_ver_from_disco_result1(QueryEl, fun crypto:md5/1);
generate_ver_from_disco_result(_QueryEl, _) ->
    unknown.

generate_ver_from_disco_result1(QueryEl, HashFun) ->
    S = generate_ver_str_from_disco_result(QueryEl),
    ?DEBUG("Calculated S for caps: ~p", [S]),
    Digest = binary_to_list(HashFun(list_to_binary(S))),
    jlib:encode_base64(Digest).

generate_ver_str_from_disco_result({xmlelement, "query", _Attrs, Els}) ->
    {IdentitiesUnsorted, FeaturesUnsorted,
     FormsUnsorted} = lists:foldl(fun({xmlelement, "identity", Attrs, _}, {Identities, Features, Forms}) ->
					  Category = xml:get_attr_s("category", Attrs),
					  Type = xml:get_attr_s("type", Attrs),
					  Lang = xml:get_attr_s("xml:lang", Attrs),
					  Name = xml:get_attr_s("name", Attrs),
					  {[{Category, Type, Lang, Name} | Identities], Features, Forms};
				     ({xmlelement, "feature", Attrs, _}, {Identities, Features, Forms}) ->
					  Var = xml:get_attr_s("var", Attrs),
					  {Identities, [Var | Features], Forms};
				     ({xmlelement, "x", Attrs, FormEls}, {Identities, Features, Forms}=Result) ->
					  case xml:get_attr_s("xmlns", Attrs) of
					      ?NS_XDATA ->
						  {FormType, Fields} = form_get_type_and_fields(FormEls),
						  {Identities, Features, [{FormType, Fields} | Forms]};
					      _ ->
						  Result
					  end;
				     (_, Result) ->
					  Result
				  end, {[], [], []}, Els),
    Identities = lists:sort(IdentitiesUnsorted),
    Features = lists:sort(FeaturesUnsorted),
    Forms = lists:map(fun({FormType, FieldUnsorted}) ->
			      Fields = lists:map(fun({Var, Values}) ->
							 {Var, lists:sort(Values)}
						 end, lists:sort(FieldUnsorted)),
			      {FormType, Fields}
		      end, lists:sort(fun({FormType1, _}, {FormType2, _}) ->
					      FormType1 < FormType2
				      end, FormsUnsorted)),
    lists:flatten([lists:map(fun({Category, Type, Lang, Name}) ->
				     [Category, "/", Type, "/", Lang, "/", Name, "<"]
			     end, Identities),
		   lists:map(fun(Feature) ->
				     [Feature, "<"]
			     end, Features),
		   lists:map(fun({FormType, Fields}) ->
				     [FormType, "<" |
				      lists:map(fun({Var, Values}) ->
							[Var, "<" |
							 lists:map(fun(Value) ->
									   [Value, "<"]
								   end, Values)]
						end, Fields)]
			     end, Forms)]).

form_get_type_and_fields(Els) ->
    form_get_type_and_fields(Els, {"", []}).

form_get_type_and_fields([{xmlelement, "field", Attrs, Children} = El | Rest], {FormType, Fields}) ->
    case xml:get_attr_s("var", Attrs) of
	"FORM_TYPE" ->
	    case xml:get_subtag(El, "value") of
		false ->
		    FormType2 = "";
		{xmlelement, "value", _, ValueEls} ->
		    FormType2 = xml:get_cdata(ValueEls)
	    end,
	    form_get_type_and_fields(Rest, {FormType2, Fields});
	Var ->
	    Values = lists:foldl(fun({xmlelement, "value", _, ValueEls}, Result) ->
					 [xml:get_cdata(ValueEls) | Result];
				    (_, Result) ->
					 Result
				 end, [], Children),
	    Field = {Var, Values},
	    form_get_type_and_fields(Rest, {FormType, [Field | Fields]})
    end;

form_get_type_and_fields([_ | Rest], Result) ->
    form_get_type_and_fields(Rest, Result);

form_get_type_and_fields([], Result) ->
    Result.
