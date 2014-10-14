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
-module(mnesia_cluster_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%% ===================================================================
%% Application callbacks
%% ===================================================================
start(normal, []) ->
    mnesia_cluster_monitor:prepare_cluster_status_files(),
    mnesia_cluster_utils:check_cluster_consistency(),

    {ok, Vsn} = application:get_key(mnesia_cluster, vsn),
    error_logger:info_msg("Starting MnesiaCluster ~s on Erlang ~s~n",
                          [Vsn, erlang:system_info(otp_release)]),
    {ok, SupPid} = mnesia_cluster_sup:start_link(),
    true = register(mnesia_cluster, self()),
    %% this blocks until wait for tables to be replicated
    mnesia_cluster_utils:init(),

    {ok, SupPid}.

stop(_State) ->
    ok = case mnesia_cluster_utils:is_clustered() of
             true  ->
                 % rabbit_amqqueue:on_node_down(node());
                 ok;
             false -> mnesia_cluster_table:clear_ram_only_tables()
         end,
    ok.
