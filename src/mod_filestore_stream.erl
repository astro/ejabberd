-module(mod_filestore_stream).

-behaviour(gen_fsm).

-define(CONNECT_TIMEOUT, 10000).
-define(RECV_TIMEOUT, 5000).

%% API
-export([start_link/3]).

%% gen_fsm callbacks
-export([init/1, unconnected/2, established/2, state_name/3, handle_event/3,
	 handle_sync_event/4, handle_info/3, terminate/3, code_change/4]).

-record(state, {listener, socket, dst}).
-include("ejabberd.hrl").

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> ok,Pid} | ignore | {error,Error}
%% Description:Creates a gen_fsm process which calls Module:init/1 to
%% initialize. To ensure a synchronized start-up procedure, this function
%% does not return until Module:init/1 has returned.  
%%--------------------------------------------------------------------
start_link(Listener, Hosts, Dst) ->
    gen_fsm:start_link(?MODULE, [Listener, Hosts, Dst], [{debug, [trace, statistics, log]}]).

%%====================================================================
%% gen_fsm callbacks
%%====================================================================
%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, StateName, State} |
%%                         {ok, StateName, State, Timeout} |
%%                         ignore                              |
%%                         {stop, StopReason}                   
%% Description:Whenever a gen_fsm is started using gen_fsm:start/[3,4] or
%% gen_fsm:start_link/3,4, this function is called by the new process to 
%% initialize. 
%%--------------------------------------------------------------------
init([Listener, Hosts, Dst]) ->
    gen_fsm:send_event(self(), {connect, Hosts}),
    {ok, unconnected, #state{listener = Listener, dst = Dst}}.

%%--------------------------------------------------------------------
%% Function: 
%% state_name(Event, State) -> {next_state, NextStateName, NextState}|
%%                             {next_state, NextStateName, 
%%                                NextState, Timeout} |
%%                             {stop, Reason, NewState}
%% Description:There should be one instance of this function for each possible
%% state name. Whenever a gen_fsm receives an event sent using
%% gen_fsm:send_event/2, the instance of this function with the same name as
%% the current state name StateName is called to handle the event. It is also 
%% called if a timeout occurs. 
%%--------------------------------------------------------------------
unconnected({connect, [{_, Host, Port} = StreamHost | Hosts]},
	    State = #state{listener = Listener, dst = Dst}) ->
    case (catch connect_socks(Host, Port, Dst)) of
	{'EXIT', Reason} ->
	    ?DEBUG("Connection to ~p failed: ~p",[StreamHost, Reason]),
	    unconnected({connect, Hosts}, State);
	Socket ->
	    ?DEBUG("Connection to ~p succeeded: ~p",[StreamHost, Socket]),
	    gen_server:cast(Listener, {streamhost_connected, self(), StreamHost}),
	    {next_state, established, State#state{socket = Socket}}
    end;

% No connection succeeded?
unconnected(_, State) ->
    {stop, cannot_connect, State}.

established({receive_file, Path, Size}, State = #state{socket = Socket}) ->
    ?DEBUG("receive_file ~p ~p",[Path,Size]),
    {ok, File} = file:open(Path, [write, raw, binary]),
    receive_to_file(Socket, File, Size),
    file:close(File),
    {stop, normal, State};
established({send_file, Path}, State = #state{socket = Socket}) ->
    ?DEBUG("send_file ~p",[Path]),
    {ok, File} = file:open(Path, [read, raw, binary]),
    send_from_file(Socket, File),
    file:close(File),
    {stop, normal, State}.

%%--------------------------------------------------------------------
%% Function:
%% state_name(Event, From, State) -> {next_state, NextStateName, NextState} |
%%                                   {next_state, NextStateName, 
%%                                     NextState, Timeout} |
%%                                   {reply, Reply, NextStateName, NextState}|
%%                                   {reply, Reply, NextStateName, 
%%                                    NextState, Timeout} |
%%                                   {stop, Reason, NewState}|
%%                                   {stop, Reason, Reply, NewState}
%% Description: There should be one instance of this function for each
%% possible state name. Whenever a gen_fsm receives an event sent using
%% gen_fsm:sync_send_event/2,3, the instance of this function with the same
%% name as the current state name StateName is called to handle the event.
%%--------------------------------------------------------------------
state_name(_Event, _From, State) ->
    Reply = ok,
    {reply, Reply, state_name, State}.

%%--------------------------------------------------------------------
%% Function: 
%% handle_event(Event, StateName, State) -> {next_state, NextStateName, 
%%						  NextState} |
%%                                          {next_state, NextStateName, 
%%					          NextState, Timeout} |
%%                                          {stop, Reason, NewState}
%% Description: Whenever a gen_fsm receives an event sent using
%% gen_fsm:send_all_state_event/2, this function is called to handle
%% the event.
%%--------------------------------------------------------------------
handle_event(_Event, StateName, State) ->
    {next_state, StateName, State}.

%%--------------------------------------------------------------------
%% Function: 
%% handle_sync_event(Event, From, StateName, 
%%                   State) -> {next_state, NextStateName, NextState} |
%%                             {next_state, NextStateName, NextState, 
%%                              Timeout} |
%%                             {reply, Reply, NextStateName, NextState}|
%%                             {reply, Reply, NextStateName, NextState, 
%%                              Timeout} |
%%                             {stop, Reason, NewState} |
%%                             {stop, Reason, Reply, NewState}
%% Description: Whenever a gen_fsm receives an event sent using
%% gen_fsm:sync_send_all_state_event/2,3, this function is called to handle
%% the event.
%%--------------------------------------------------------------------
handle_sync_event(Event, From, StateName, State) ->
    Reply = ok,
    {reply, Reply, StateName, State}.

%%--------------------------------------------------------------------
%% Function: 
%% handle_info(Info,StateName,State)-> {next_state, NextStateName, NextState}|
%%                                     {next_state, NextStateName, NextState, 
%%                                       Timeout} |
%%                                     {stop, Reason, NewState}
%% Description: This function is called by a gen_fsm when it receives any
%% other message than a synchronous or asynchronous event
%% (or a system message).
%%--------------------------------------------------------------------
handle_info(_Info, StateName, State) ->
    {next_state, StateName, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, StateName, State) -> void()
%% Description:This function is called by a gen_fsm when it is about
%% to terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_fsm terminates with
%% Reason. The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, _StateName, _State) ->
    % TODO: delete 0-byte files
    ok.

%%--------------------------------------------------------------------
%% Function:
%% code_change(OldVsn, StateName, State, Extra) -> {ok, StateName, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

connect_socks(Host, Port, DstS) ->
    ?DEBUG("connect(~p, ~p)",[Host,Port]),
    {ok, Socket} = gen_tcp:connect(Host, Port, [binary, {active, false}], ?CONNECT_TIMEOUT),
    ok = gen_tcp:send(Socket, <<5, 1, 0>>),
    {ok, <<5, 0>>} =  gen_tcp:recv(Socket, 2, ?RECV_TIMEOUT),

    Dst = list_to_binary(DstS),
    DstLen = size(Dst),
    ?DEBUG("sending connect request",[]),
    ok = gen_tcp:send(Socket, <<5, 1, 0, 3, DstLen:8, Dst/binary, 0, 0>>),
    ?DEBUG("waiting for connect reply",[]),
    {ok, <<5, 0, _:8, ATyp:8>>} = gen_tcp:recv(Socket, 4, ?RECV_TIMEOUT),
    ALen = case ATyp of
	       0 -> % None
		   0;
	       1 -> % IPv4
		   4;
	       3 -> % Domain
		   ?DEBUG("waiting for domain length",[]),
		   {ok, <<Len:8>>} = gen_tcp:recv(Socket, 1, ?RECV_TIMEOUT),
		   Len;
	       4 -> % IPv6
		   16
	   end,
    % Addr + Port
    ?DEBUG("waiting for address",[]),
    {ok, _} = gen_tcp:recv(Socket, ALen + 2, ?RECV_TIMEOUT),
    ?DEBUG("OK",[]),
    Socket.

receive_to_file(Socket, File, Size) ->
    if
	Size > 512 -> ChunkSize = 512;
	true -> ChunkSize = Size
    end,
    {ok, Data} = gen_tcp:recv(Socket, ChunkSize, ?RECV_TIMEOUT),
    file:write(File, Data),
    if
	size(Data) < Size ->
	    receive_to_file(Socket, File, Size - size(Data));
	true ->
	    done
    end.

send_from_file(Socket, File) ->
    case file:read(File, 512) of
	{ok, Data} ->
	    %?DEBUG("~p reads ~p bytes",[File,size(Data)]),
	    ok = gen_tcp:send(Socket, Data),
	    send_from_file(Socket, File);
	_ ->
	    ok
    end.
