%%%----------------------------------------------------------------------
%%% File    : ejabberd_s2s.erl
%%% Author  : Alexey Shchepin <alexey@sevcom.net>
%%% Purpose : 
%%% Created :  7 Dec 2002 by Alexey Shchepin <alexey@sevcom.net>
%%% Id      : $Id$
%%%----------------------------------------------------------------------

-module(ejabberd_s2s).
-author('alexey@sevcom.net').
-vsn('$Revision$ ').

-export([start/0, init/0,
	 have_connection/1,
	 get_key/1,
	 try_register/1]).

-include_lib("mnemosyne/include/mnemosyne.hrl").
-include("ejabberd.hrl").

-record(s2s, {server, node, key}).
-record(mys2s, {server, pid}).


start() ->
    spawn(ejabberd_s2s, init, []).

init() ->
    register(ejabberd_s2s, self()),
    mnesia:create_table(s2s,[{ram_copies, [node()]},
			     {attributes, record_info(fields, s2s)}]),
    mnesia:add_table_index(session, node),
    mnesia:create_table(mys2s,
			[{ram_copies, [node()]},
			 {local_content, true},
			 {attributes, record_info(fields, mys2s)}]),
    mnesia:subscribe(system),
    loop().

loop() ->
    receive
	%{open_connection, User, Resource, From} ->
	%    replace_and_register_my_connection(User, Resource, From),
	%    replace_alien_connection(User, Resource),
	%    loop();
	{closed_conection, Server} ->
	    remove_connection(Server),
	    loop();
	%{replace, User, Resource} ->
	%    replace_my_connection(User, Resource),
	%    loop();
	{mnesia_system_event, {mnesia_down, Node}} ->
	    clean_table_from_bad_node(Node),
	    loop();
	{route, From, To, Packet} ->
	    do_route(From, To, Packet),
	    loop();
	_ ->
	    loop()
    end.


%open_session(User, Resource) ->
%    ejabberd_s2s ! {open_session, User, Resource, self()}.
%
%close_session(User, Resource) ->
%    ejabberd_s2s ! {close_session, User, Resource}.


remove_connection(Server) ->
    F = fun() ->
		mnesia:delete({mys2s, Server}),
		mnesia:delete({s2s, Server})
	end,
    mnesia:transaction(F).



clean_table_from_bad_node(Node) ->
    F = fun() ->
		Es = mnesia:index_read(s2s, Node, #s2s.node),
		lists:foreach(fun(E) ->
				      mnesia:delete_object(s2s, E, write)
			      end, Es)
        end,
    mnesia:transaction(F).

have_connection(Server) ->
    F = fun() ->
		[E] = mnesia:read({s2s, Server})
        end,
    case mnesia:transaction(F) of
	{atomic, _} ->
	    true;
	_ ->
	    false
    end.

get_key(Server) ->
    F = fun() ->
		[E] = mnesia:read({s2s, Server}),
		E
        end,
    case mnesia:transaction(F) of
	{atomic, E} ->
	    E#s2s.key;
	_ ->
	    ""
    end.

try_register(Server) ->
    Key = randoms:get_string(),
    F = fun() ->
		case mnesia:read({s2s, Server}) of
		    [] ->
			mnesia:write(#s2s{server = Server,
					  node = node(),
					  key = Key}),
			mnesia:write(#mys2s{server = Server,
					    pid = self()}),
			{key, Key};
		    _ ->
			false
		end
        end,
    case mnesia:transaction(F) of
	{atomic, Res} ->
	    Res;
	_ ->
	    false
    end.



%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

do_route(From, To, Packet) ->
    ?DEBUG("s2s manager~n\tfrom ~p~n\tto ~p~n\tpacket ~P~n",
	   [From, To, Packet, 8]),
    {_, MyServer, _} = From,
    {User, Server, Resource} = To,
    Key = randoms:get_string(),
    F = fun() ->
		case mnesia:read({mys2s, Server}) of
		    [] ->
			case mnesia:read({s2s, Server}) of
			    [Er] ->
				{remote, Er#s2s.node};
			    [] ->
				% TODO
				mnesia:write(#s2s{server = Server,
						  node = node(),
						  key = Key}),
				new
			end;
		    [El] ->
			{local, El#mys2s.pid}
		end
        end,
    case mnesia:transaction(F) of
	{atomic, {local, Pid}} ->
	    ?DEBUG("sending to process ~p~n", [Pid]),
	    % TODO
	    {xmlelement, Name, Attrs, Els} = Packet,
	    NewAttrs = jlib:replace_from_to_attrs(jlib:jid_to_string(From),
						  jlib:jid_to_string(To),
						  Attrs),
	    send_element(Pid, {xmlelement, Name, NewAttrs, Els}),
	    ok;
	{atomic, {remote, Node}} ->
	    ?DEBUG("sending to node ~p~n", [Node]),
	    {ejabberd_s2s, Node} ! {route, From, To, Packet},
	    ok;
	{atomic, new} ->
	    ?DEBUG("starting new s2s connection~n", []),
	    Pid = ejabberd_s2s_out:start(MyServer, Server, {new, Key}),
	    mnesia:transaction(fun() -> mnesia:write(#mys2s{server = Server,
							    pid = Pid}) end),
	    {xmlelement, Name, Attrs, Els} = Packet,
	    NewAttrs = jlib:replace_from_to_attrs(jlib:jid_to_string(From),
						  jlib:jid_to_string(To),
						  Attrs),
	    send_element(Pid, {xmlelement, Name, NewAttrs, Els}),
	    ok;
	{atomic, not_exists} ->
	    ?DEBUG("packet droped~n", []),
	    ok;
	{aborted, Reason} ->
	    ?DEBUG("delivery failed: ~p~n", [Reason]),
	    false
    end.

send_element(Pid, El) ->
    Pid ! {send_element, El}.
