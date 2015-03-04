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
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is GoPivotal, Inc.
%% Copyright (c) 2007-2014 GoPivotal, Inc.  All rights reserved.
%%

-module(mnesia_cluster_monitor).

-behaviour(gen_server).

-export([start_link/1]).
-export([running_nodes_filename/0,
         cluster_status_filename/0, prepare_cluster_status_files/0,
         write_cluster_status/1, read_cluster_status/0,
         update_cluster_status/0, reset_cluster_status/0]).
-export([notify_node_up/0, notify_joined_cluster/0, notify_left_cluster/1]).
-export([partitions/0, partitions/1, subscribe/1]).
-export([pause_minority_guard/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).

 %% Utils
-export([all_app_nodes_up/0, run_outside_applications/1, ping_all/0]).

-define(SERVER, ?MODULE).
-define(MNESIA_CLUSTER_UP_RPC_TIMEOUT, 2000).
-define(MNESIA_CLUSTER_DOWN_PING_INTERVAL, 1000).

-record(state, {app, monitors, partitions, subscribers, down_ping_timer, autoheal}).

%%----------------------------------------------------------------------------
%% Start
%%----------------------------------------------------------------------------

start_link(App) -> gen_server:start_link({local, ?SERVER}, ?MODULE, [App], []).

%%----------------------------------------------------------------------------
%% Cluster file operations
%%----------------------------------------------------------------------------

%% The cluster file information is kept in two files.  The "cluster
%% status file" contains all the clustered nodes and the disc nodes.
%% The "running nodes file" contains the currently running nodes or
%% the running nodes at shutdown when the node is down.
%%
%% We strive to keep the files up to date and we rely on this
%% assumption in various situations. Obviously when mnesia is offline
%% the information we have will be outdated, but it cannot be
%% otherwise.

running_nodes_filename() ->
    filename:join(mnesia_cluster_utils:dir(), "nodes_running_at_shutdown").

cluster_status_filename() ->
    mnesia_cluster_utils:dir() ++ "/cluster_nodes.config".

prepare_cluster_status_files() ->
    mnesia_cluster_utils:ensure_mnesia_dir(),
    Corrupt = fun(F) -> throw({error, corrupt_cluster_status_files, F}) end,
    RunningNodes1 = case try_read_file(running_nodes_filename()) of
                        {ok, [Nodes]} when is_list(Nodes) -> Nodes;
                        {ok, Other}                       -> Corrupt(Other);
                        {error, enoent}                   -> []
                    end,
    ThisNode = [node()],
    %% The running nodes file might contain a set or a list, in case
    %% of the legacy file
    RunningNodes2 = lists:usort(ThisNode ++ RunningNodes1),
    {AllNodes1, DiscNodes} =
        case try_read_file(cluster_status_filename()) of
            {ok, [{AllNodes, DiscNodes0}]} ->
                {AllNodes, DiscNodes0};
            {ok, [AllNodes0]} when is_list(AllNodes0) ->
                {legacy_cluster_nodes(AllNodes0), legacy_disc_nodes(AllNodes0)};
            {ok, Files} ->
                Corrupt(Files);
            {error, enoent} ->
                LegacyNodes = legacy_cluster_nodes([]),
                {LegacyNodes, LegacyNodes}
        end,
    AllNodes2 = lists:usort(AllNodes1 ++ RunningNodes2),
    ok = write_cluster_status({AllNodes2, DiscNodes, RunningNodes2}).

write_cluster_status({All, Disc, Running}) ->
    ClusterStatusFN = cluster_status_filename(),
    Res = case mnesia_cluster_file:write_term_file(ClusterStatusFN, [{All, Disc}]) of
              ok ->
                  RunningNodesFN = running_nodes_filename(),
                  {RunningNodesFN,
                   mnesia_cluster_file:write_term_file(RunningNodesFN, [Running])};
              E1 = {error, _} ->
                  {ClusterStatusFN, E1}
          end,
    case Res of
        {_, ok}           -> ok;
        {FN, {error, E2}} -> throw({error, {could_not_write_file, FN, E2}})
    end.

read_cluster_status() ->
    case {try_read_file(cluster_status_filename()),
          try_read_file(running_nodes_filename())} of
        {{ok, [{All, Disc}]}, {ok, [Running]}} when is_list(Running) ->
            {All, Disc, Running};
        {Stat, Run} ->
            throw({error, {corrupt_or_missing_cluster_files, Stat, Run}})
    end.

update_cluster_status() ->
    {ok, Status} = mnesia_cluster_utils:cluster_status_from_mnesia(),
    write_cluster_status(Status).

reset_cluster_status() ->
    write_cluster_status({[node()], [node()], [node()]}).

%%----------------------------------------------------------------------------
%% Cluster notifications
%%----------------------------------------------------------------------------

notify_node_up() ->
    Nodes = mnesia_cluster_utils:cluster_nodes(running) -- [node()],
    gen_server:abcast(Nodes, ?SERVER,
                      {node_up, node(), mnesia_cluster_utils:node_type()}),
    %% register other active cluster nodes with this cluster monitor
    DiskNodes = mnesia_cluster_utils:cluster_nodes(disc),
    [gen_server:cast(?SERVER, {node_up, N, case lists:member(N, DiskNodes) of
                                               true  -> disc;
                                               false -> ram
                                           end}) || N <- Nodes],
    ok.

notify_joined_cluster() ->
    Nodes = mnesia_cluster_utils:cluster_nodes(running) -- [node()],
    gen_server:abcast(Nodes, ?SERVER,
                      {joined_cluster, node(), mnesia_cluster_utils:node_type()}),
    ok.

notify_left_cluster(Node) ->
    Nodes = mnesia_cluster_utils:cluster_nodes(running),
    gen_server:abcast(Nodes, ?SERVER, {left_cluster, Node}),
    ok.

%%----------------------------------------------------------------------------
%% Server calls
%%----------------------------------------------------------------------------

partitions() ->
    gen_server:call(?SERVER, partitions, infinity).

partitions(Nodes) ->
    {Replies, _} = gen_server:multi_call(Nodes, ?SERVER, partitions, infinity),
    Replies.

subscribe(Pid) ->
    gen_server:cast(?SERVER, {subscribe, Pid}).

%%----------------------------------------------------------------------------
%% pause_minority safety
%%----------------------------------------------------------------------------

%% If we are in a minority and pause_minority mode then a) we are
%% going to shut down imminently and b) we should not confirm anything
%% until then, since anything we confirm is likely to be lost.
%%
%% We could confirm something by having an HA queue see the minority
%% state (and fail over into it) before the node monitor stops us, or
%% by using unmirrored queues and just having them vanish (and
%% confiming messages as thrown away).
%%
%% So we have channels call in here before issuing confirms, to do a
%% lightweight check that we have not entered a minority state.

pause_minority_guard() ->
    case get(pause_minority_guard) of
        not_minority_mode ->
            ok;
        undefined ->
            {ok, M} = application:get_env(mnesia_cluster, cluster_partition_handling),
            case M of
                pause_minority -> pause_minority_guard([]);
                _              -> put(pause_minority_guard, not_minority_mode),
                                  ok
            end;
        {minority_mode, Nodes} ->
            pause_minority_guard(Nodes)
    end.

pause_minority_guard(LastNodes) ->
    case nodes() of
        LastNodes -> ok;
        _         -> put(pause_minority_guard, {minority_mode, nodes()}),
                     case majority() of
                         false -> pausing;
                         true  -> ok
                     end
    end.

%%----------------------------------------------------------------------------
%% gen_server callbacks
%%----------------------------------------------------------------------------

init([App]) ->
    %% We trap exits so that the supervisor will not just kill us. We
    %% want to be sure that we are not going to be killed while
    %% writing out the cluster status files - bad things can then
    %% happen.
    process_flag(trap_exit, true),
    net_kernel:monitor_nodes(true, [nodedown_reason]),
    {ok, _} = mnesia:subscribe(system),
    {ok, #state{app         = App,
                monitors    = mnesia_cluster_pmon:new(),
                subscribers = mnesia_cluster_pmon:new(),
                partitions  = [],
                autoheal    = mnesia_cluster_autoheal:init()}}.

handle_call(partitions, _From, State = #state{partitions = Partitions}) ->
    {reply, Partitions, State};

handle_call(_Request, _From, State) ->
    {noreply, State}.

%% Note: when updating the status file, we can't simply write the
%% mnesia information since the message can (and will) overtake the
%% mnesia propagation.
handle_cast({node_up, Node, NodeType},
            State = #state{app=App, monitors = Monitors, subscribers = Subscribers}) ->
    case mnesia_cluster_pmon:is_monitored({App, Node}, Monitors) of
        true  -> {noreply, State};
        false -> error_logger:info_msg("~p on node ~p up~n", [App, Node]),
                 {AllNodes, DiscNodes, RunningNodes} = read_cluster_status(),
                 write_cluster_status({add_node(Node, AllNodes),
                                       case NodeType of
                                           disc -> add_node(Node, DiscNodes);
                                           ram  -> DiscNodes
                                       end,
                                       add_node(Node, RunningNodes)}),
                 [P ! {node_up, Node} || P <- mnesia_cluster_pmon:monitored(Subscribers)],
                 ok = handle_live_app(Node),
                 {noreply, State#state{
                             monitors = mnesia_cluster_pmon:monitor({App, Node}, Monitors)}}
    end;

handle_cast({joined_cluster, Node, NodeType}, State) ->
    {AllNodes, DiscNodes, RunningNodes} = read_cluster_status(),
    write_cluster_status({add_node(Node, AllNodes),
                          case NodeType of
                              disc -> add_node(Node, DiscNodes);
                              ram  -> DiscNodes
                          end,
                          RunningNodes}),
    {noreply, State};
handle_cast({left_cluster, Node}, State) ->
    {AllNodes, DiscNodes, RunningNodes} = read_cluster_status(),
    write_cluster_status({del_node(Node, AllNodes), del_node(Node, DiscNodes),
                          del_node(Node, RunningNodes)}),
    {noreply, State};
handle_cast({subscribe, Pid}, State = #state{subscribers = Subscribers}) ->
    {noreply, State#state{subscribers = mnesia_cluster_pmon:monitor(Pid, Subscribers)}};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'DOWN', _MRef, process, {App, Node}, _Reason},
            State = #state{app=App, monitors = Monitors, subscribers = Subscribers}) ->
    error_logger:info_msg("~p on node ~p down~n", [App, Node]),
    {AllNodes, DiscNodes, RunningNodes} = read_cluster_status(),
    write_cluster_status({AllNodes, DiscNodes, del_node(Node, RunningNodes)}),
    [P ! {node_down, Node} || P <- mnesia_cluster_pmon:monitored(Subscribers)],
    {noreply, handle_dead_app(
                Node,
                State#state{monitors = mnesia_cluster_pmon:erase({App, Node}, Monitors)})};

handle_info({'DOWN', _MRef, process, Pid, _Reason},
            State = #state{subscribers = Subscribers}) ->
    {noreply, State#state{subscribers = mnesia_cluster_pmon:erase(Pid, Subscribers)}};

handle_info({nodedown, Node, Info}, State) ->
    error_logger:info_msg("node ~p down: ~p~n",
                    [Node, proplists:get_value(nodedown_reason, Info)]),
    {noreply, handle_dead_node(Node, State)};
handle_info({nodeup, Node, _}, State) ->
    %% we signal the app watcher to redeliver the app alive signal
    %% this will result in handle_cast({node_up.. on all running nodes
    error_logger:info_msg("node ~p down~n", [Node]),
    {noreply, State};
handle_info({mnesia_system_event,
             {inconsistent_database, running_partitioned_network, Node}},
            State = #state{app        = App,
                           partitions = Partitions,
                           monitors   = Monitors,
                           autoheal   = AState}) ->
    %% We will not get a node_up from this node - yet we should treat it as
    %% up (mostly).
    State1 = case mnesia_cluster_pmon:is_monitored({App, Node}, Monitors) of
                 true  -> State;
                 false -> State#state{
                            monitors = mnesia_cluster_pmon:monitor({App, Node}, Monitors)}
             end,
    ok = handle_live_app(Node),
    Partitions1 = ordsets:to_list(
                    ordsets:add_element(Node, ordsets:from_list(Partitions))),
    {noreply, State1#state{partitions = Partitions1,
                           autoheal   = mnesia_cluster_autoheal:maybe_start(AState)}};

handle_info({autoheal_msg, Msg}, State = #state{autoheal   = AState,
                                                partitions = Partitions}) ->
    AState1 = mnesia_cluster_autoheal:handle_msg(Msg, AState, Partitions),
    {noreply, State#state{autoheal = AState1}};

handle_info(ping_nodes, State) ->
    %% We ping nodes when some are down to ensure that we find out
    %% about healed partitions quickly. We ping all nodes rather than
    %% just the ones we know are down for simplicity; it's not expensive
    %% to ping the nodes that are up, after all.
    State1 = State#state{down_ping_timer = undefined},
    Self = self(),
    %% We ping in a separate process since in a partition it might
    %% take some noticeable length of time and we don't want to block
    %% the node monitor for that long.
    spawn_link(fun () ->
                       ping_all(),
                       case all_nodes_up() of
                           true  -> ok;
                           false -> Self ! ping_again
                       end
               end),
    {noreply, State1};

handle_info(ping_again, State) ->
    {noreply, ensure_ping_timer(State)};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    stop_timer(State, #state.down_ping_timer),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%----------------------------------------------------------------------------
%% Functions that call the module specific hooks when nodes go up/down
%%----------------------------------------------------------------------------

handle_dead_node(Node, State = #state{autoheal = Autoheal}) ->
    %% In general in mnesia_cluster_monitor we care about whether the
    %% defined App application is up rather than the node.
    %%
    %% However, for pause_minority mode we can't do this, since we
    %% depend on looking at whether other nodes are up to decide
    %% whether to come back up ourselves - if we decide that based on
    %% the defined App application we would go down and never come back.
    case application:get_env(mnesia_cluster, cluster_partition_handling) of
        {ok, pause_minority} ->
            case majority() of
                true  -> ok;
                false -> await_cluster_recovery()
            end,
            State;
        {ok, ignore} ->
            State;
        {ok, autoheal} ->
            State#state{autoheal = mnesia_cluster_autoheal:node_down(Node, Autoheal)};
        {ok, Term} ->
            error_logger:warning_msg("cluster_partition_handling ~p unrecognised, "
                               "assuming 'ignore'~n", [Term]),
            State
    end.

await_cluster_recovery() ->
    error_logger:warning_msg("Cluster minority status detected - awaiting recovery~n",
                       []),
    run_outside_applications(fun () ->
                                     mnesia_cluster:stop(),
                                     wait_for_cluster_recovery()
                             end),
    ok.

run_outside_applications(Fun) ->
    spawn(fun () ->
                  %% If our group leader is inside an application we are about
                  %% to stop, application:stop/1 does not return.
                  group_leader(whereis(init), self()),
                  %% Ensure only one such process at a time, the
                  %% exit(badarg) is harmless if one is already running
                  try register(mnesia_cluster_outside_app_process, self()) of
                      true           -> Fun()
                  catch error:badarg -> ok
                  end
          end).

wait_for_cluster_recovery() ->
    ping_all(),
    case majority() of
        true  -> mnesia_cluster:start();
        false -> timer:sleep(?MNESIA_CLUSTER_DOWN_PING_INTERVAL),
                 wait_for_cluster_recovery()
    end.

handle_dead_app(Node, State = #state{partitions = Partitions,
                                        autoheal   = Autoheal}) ->
    %% TODO: This may turn out to be a performance hog when there are
    %% lots of nodes.  We really only need to execute some of these
    %% statements on *one* node, rather than all of them.
    ok = mnesia_cluster_utils:on_node_down(Node),
    %% If we have been partitioned, and we are now in the only remaining
    %% partition, we no longer care about partitions - forget them. Note
    %% that we do not attempt to deal with individual (other) partitions
    %% going away. It's only safe to forget anything about partitions when
    %% there are no partitions.
    Partitions1 = case Partitions -- (Partitions -- alive_app_nodes()) of
                      [] -> [];
                      _  -> Partitions
                  end,
    ensure_ping_timer(
      State#state{partitions = Partitions1,
                  autoheal   = mnesia_cluster_autoheal:app_node_down(Node, Autoheal)}).

ensure_ping_timer(State) ->
    ensure_timer(
      State, #state.down_ping_timer, ?MNESIA_CLUSTER_DOWN_PING_INTERVAL, ping_nodes).

handle_live_app(Node) ->
    ok = mnesia_cluster_utils:on_node_up(Node).

%%--------------------------------------------------------------------
%% Internal utils
%%--------------------------------------------------------------------

try_read_file(FileName) ->
    case mnesia_cluster_file:read_term_file(FileName) of
        {ok, Term}      -> {ok, Term};
        {error, enoent} -> {error, enoent};
        {error, E}      -> throw({error, {cannot_read_file, FileName, E}})
    end.

legacy_cluster_nodes(Nodes) ->
    %% We get all the info that we can, including the nodes from
    %% mnesia, which will be there if the node is a disc node (empty
    %% list otherwise)
    lists:usort(Nodes ++ mnesia:system_info(db_nodes)).

legacy_disc_nodes(AllNodes) ->
    case AllNodes == [] orelse lists:member(node(), AllNodes) of
        true  -> [node()];
        false -> []
    end.

add_node(Node, Nodes) -> lists:usort([Node | Nodes]).

del_node(Node, Nodes) -> Nodes -- [Node].

%%--------------------------------------------------------------------

%% mnesia:system_info(db_nodes) (and hence
%% mnesia_cluster_utils:cluster_nodes(running)) does not give reliable
%% results when partitioned. So we have a small set of replacement
%% functions here. "app" in a function's name implies we test if
%% the defined App application is up, not just the node.

%% As we use these functions to decide what to do in pause_minority
%% state, they *must* be fast, even in the case where TCP connections
%% are timing out. So that means we should be careful about whether we
%% connect to nodes which are currently disconnected.

majority() ->
    Nodes = mnesia_cluster_utils:cluster_nodes(all),
    length(alive_nodes(Nodes)) / length(Nodes) > 0.5.

all_nodes_up() ->
    Nodes = mnesia_cluster_utils:cluster_nodes(all),
    length(alive_nodes(Nodes)) =:= length(Nodes).

all_app_nodes_up() ->
    Nodes = mnesia_cluster_utils:cluster_nodes(all),
    length(alive_app_nodes(Nodes)) =:= length(Nodes).

alive_nodes(Nodes) -> [N || N <- Nodes, lists:member(N, [node()|nodes()])].

alive_app_nodes() -> alive_app_nodes(mnesia_cluster_utils:cluster_nodes(all)).

alive_app_nodes(Nodes) ->
    [N || N <- alive_nodes(Nodes), mnesia_cluster_utils:is_running(N)].

%% This one is allowed to connect!
ping_all() ->
    [net_adm:ping(N) || N <- mnesia_cluster_utils:cluster_nodes(all)],
    ok.

ensure_timer(State, Idx, After, Msg) ->
    case element(Idx, State) of
        undefined -> TRef = erlang:send_after(After, self(), Msg),
                     setelement(Idx, State, TRef);
        _         -> State
    end.

stop_timer(State, Idx) ->
    case element(Idx, State) of
        undefined -> State;
        TRef      -> erlang:cancel_timer(TRef),
                     setelement(Idx, State, undefined)
    end.
