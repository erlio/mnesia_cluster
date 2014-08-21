-module(mnesia_cluster_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

%% Helper macro for declaring children of supervisor
-define(CHILD(I, Type, Args), {I, {I, start_link, Args}, permanent, 5000, Type, [I]}).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
    {ok, AppProccess} = application:get_env(mnesia_cluster, app_process),
    supervisor:start_link({local, ?MODULE}, ?MODULE, [AppProccess]).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([AppProccess]) ->
    {ok, { {one_for_one, 5, 10},
           [?CHILD(file_handle_cache, worker, []),
            ?CHILD(mnesia_cluster_monitor, worker, [AppProccess]),
            ?CHILD(mnesia_cluster_app_watcher, worker, [AppProccess])
           ]} }.

