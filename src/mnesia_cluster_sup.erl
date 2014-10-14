%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% Copyright (c) 2014 Erlio GmbH, Basel Switzerland. All rights reserved.
%%
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

