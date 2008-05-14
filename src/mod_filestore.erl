-module(mod_filestore).
-author('astro@spaceboyz.net').

-behaviour(gen_mod).
-behaviour(supervisor).

%% gen_mod callbacks.
-export([start/2, stop/1]).

%% supervisor callbacks.
-export([init/1]).

%% API.
-export([start_link/2]).

-define(PROCNAME, ejabberd_mod_filestore).

start(Host, Opts) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    ChildSpec = {
      Proc, {?MODULE, start_link, [Host, Opts]},
      transient, infinity, supervisor, [?MODULE]
     },
    supervisor:start_child(ejabberd_sup, ChildSpec).

stop(Host) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    supervisor:terminate_child(ejabberd_sup, Proc),
    supervisor:delete_child(ejabberd_sup, Proc).

start_link(Host, Opts) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    supervisor:start_link({local, Proc}, ?MODULE, [Host, Opts]).

init([Host, Opts]) ->
    Service =
	{mod_filestore_service, {mod_filestore_service, start_link, [Host, Opts]},
	 transient, 5000, worker, [mod_filestore_service]},
    {ok, {{one_for_one, 10, 1},
	  [Service]}}.
