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
