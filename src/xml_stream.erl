%%%----------------------------------------------------------------------
%%% File    : xml_stream.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : Parse XML streams
%%% Created : 17 Nov 2002 by Alexey Shchepin <alexey@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2008   ProcessOne
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

-module(xml_stream).
-author('alexey@process-one.net').

-export([new/1,
	 new/2,
	 parse/2,
	 close/1,
	 parse_element/1]).

-define(XML_START, 0).
-define(XML_END,   1).
-define(XML_CDATA, 2).
-define(XML_ERROR, 3).

-define(PARSE_COMMAND, 0).
-define(PARSE_FINAL_COMMAND, 1).

-record(xml_stream_state, {callback_pid, port, stack, size, maxsize}).

process_data(CallbackPid, Stack, Data) ->
    case Data of
	{?XML_START, {Name, Attrs}} ->
	    NewStack = [{xmlelement, Name, Attrs, []} | Stack],
	    % Is there a namespace prefix in the element's name or in
	    % any of the attribute's names which has not been defined
	    % in this element or one of its parents (up the stack)?
	    BadNamespacePrefix = lists:any(fun(NodeName) ->
						   not(is_valid_namespace_prefix(NodeName, NewStack))
					   end, [Name | lists:map(fun({AttrName, _AttrValue}) ->
									  AttrName
								  end, Attrs)]),
	    if
		BadNamespacePrefix ->
		    catch gen_fsm:send_event(CallbackPid,
					     {xmlstreamerror, bad_namespace_prefix});
		Stack == [] ->
		    catch gen_fsm:send_event(CallbackPid,
					     {xmlstreamstart, Name, Attrs});
		true ->
		    ok
	    end,
	    NewStack;
	{?XML_END, EndName} ->
	    case Stack of
		[{xmlelement, Name, Attrs, Els} | Tail] ->
		    NewEl = {xmlelement, Name, Attrs, lists:reverse(Els)},
		    case Tail of
			[] ->
			    catch gen_fsm:send_event(CallbackPid,
						     {xmlstreamend, EndName}),
			    Tail;
			[_] ->
			    catch gen_fsm:send_event(CallbackPid,
						     {xmlstreamelement, NewEl}),
			    Tail;
			[{xmlelement, Name1, Attrs1, Els1} | Tail1] ->
			    [{xmlelement, Name1, Attrs1, [NewEl | Els1]} |
			     Tail1]
		    end
	    end;
	{?XML_CDATA, CData} ->
	    case Stack of
		[El] ->
		    [El];
		%% Merge CDATA nodes if they are contiguous
		%% This does not change the semantic: the split in
		%% several CDATA nodes depends on the TCP/IP packet
		%% fragmentation
		[{xmlelement, Name, Attrs,
		  [{xmlcdata, PreviousCData}|Els]} | Tail] ->
		    [{xmlelement, Name, Attrs,
		      [{xmlcdata, concat_binary([PreviousCData, CData])} | Els]} | Tail];
		%% No previous CDATA
		[{xmlelement, Name, Attrs, Els} | Tail] ->
		    [{xmlelement, Name, Attrs, [{xmlcdata, CData} | Els]} |
		     Tail];
		[] -> []
	    end;
	{?XML_ERROR, Err} ->
	    catch gen_fsm:send_event(CallbackPid, {xmlstreamerror, Err})
    end.


new(CallbackPid) ->
    new(CallbackPid, infinity).

new(CallbackPid, MaxSize) ->
    Port = open_port({spawn, expat_erl}, [binary]),
    #xml_stream_state{callback_pid = CallbackPid,
		      port = Port,
		      stack = [],
		      size = 0,
		      maxsize = MaxSize}.


parse(#xml_stream_state{callback_pid = CallbackPid,
			port = Port,
			stack = Stack,
			size = Size,
			maxsize = MaxSize} = State, Str) ->
    StrSize = if
		  is_list(Str) -> length(Str);
		  is_binary(Str) -> size(Str)
	      end,
    Res = port_control(Port, ?PARSE_COMMAND, Str),
    {NewStack, NewSize} =
	lists:foldl(
	  fun(Data, {St, Sz}) ->
		  NewSt = process_data(CallbackPid, St, Data),
		  case NewSt of
		      [_] -> {NewSt, 0};
		      _ -> {NewSt, Sz}
		  end
	  end, {Stack, Size + StrSize}, binary_to_term(Res)),
    if
	NewSize > MaxSize ->
	    catch gen_fsm:send_event(CallbackPid,
				     {xmlstreamerror, "XML stanza is too big"});
	true ->
	    ok
    end,
    State#xml_stream_state{stack = NewStack, size = NewSize}.

close(#xml_stream_state{port = Port}) ->
    port_close(Port).


parse_element(Str) ->
    Port = open_port({spawn, expat_erl}, [binary]),
    Res = port_control(Port, ?PARSE_FINAL_COMMAND, Str),
    port_close(Port),
    process_element_events(binary_to_term(Res)).

process_element_events(Events) ->
    process_element_events(Events, []).

process_element_events([], _Stack) ->
    {error, parse_error};
process_element_events([Event | Events], Stack) ->
    case Event of
	{?XML_START, {Name, Attrs}} ->
	    process_element_events(
	      Events, [{xmlelement, Name, Attrs, []} | Stack]);
	{?XML_END, _EndName} ->
	    case Stack of
		[{xmlelement, Name, Attrs, Els} | Tail] ->
		    NewEl = {xmlelement, Name, Attrs, lists:reverse(Els)},
		    case Tail of
			[] ->
			    if
				Events == [] ->
				    NewEl;
				true ->
				    {error, parse_error}
			    end;
			[{xmlelement, Name1, Attrs1, Els1} | Tail1] ->
			    process_element_events(
			      Events,
			      [{xmlelement, Name1, Attrs1, [NewEl | Els1]} |
			       Tail1])
		    end
	    end;
	{?XML_CDATA, CData} ->
	    case Stack of
		[{xmlelement, Name, Attrs, Els} | Tail] ->
		    process_element_events(
		      Events, 
		      [{xmlelement, Name, Attrs, [{xmlcdata, CData} | Els]} |
		       Tail]);
		[] ->
		    process_element_events(Events, [])
	    end;
	{?XML_ERROR, Err} ->
	    {error, Err}
    end.

is_valid_namespace_prefix(NodeName, Stack) ->
    case string:tokens(NodeName, ":") of
	["xml", _] ->
	    true;
	["xmlns", _] ->
	    true;
	[Prefix, _] ->
	    prefix_has_namespace(Prefix, Stack);
	[_] ->
	    true
    end.

prefix_has_namespace(_Prefix, []) ->
    false;
prefix_has_namespace(Prefix, [{xmlelement, _, Attrs, _} | Stack]) ->
    PrefixDefined = lists:any(fun({"xmlns:" ++ Prefix2, _AttrValue}) when Prefix2 == Prefix ->
				      true;
				 (_) ->
				      false
			      end, Attrs),
    if
	PrefixDefined ->
	    true;
	true ->
	    prefix_has_namespace(Prefix, Stack)
    end.
