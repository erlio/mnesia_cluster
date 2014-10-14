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
-module(mnesia_cluster).

-export([start/0, stop/0]).


start() ->
    application:ensure_all_started(mnesia_cluster).

stop() ->
    application:stop(mnesia_cluster),
    application:stop(mnesia).

%% start() ->
%%     start_it(fun() ->
%%                      %% We do not want to HiPE compile or upgrade
%%                      %% mnesia after just restarting the app
%%                      ok = ensure_application_loaded(),
%%                      mnesia_cluster_monitor:prepare_cluster_status_files(),
%%                      mnesia_cluster_utils:check_cluster_consistency(),
%%                      start_apps(?APPS)
%%              end).
%%
%% start_it(StartFun) ->
%%     Marker = spawn_link(fun() -> receive stop -> ok end end),
%%     case catch register(mnesia_cluster_boot, Marker) of
%%         true -> try
%%                     case is_running() of
%%                         true  -> ok;
%%                         false -> StartFun()
%%                     end
%%                 catch
%%                     throw:{could_not_start, _App, _Reason}=Err ->
%%                         boot_error(Err, not_available);
%%                     _:Reason ->
%%                         boot_error(Reason, erlang:get_stacktrace())
%%                 after
%%                     unlink(Marker),
%%                     Marker ! stop,
%%                     %% give the error loggers some time to catch up
%%                     timer:sleep(100)
%%                 end;
%%         _    -> unlink(Marker),
%%                 Marker ! stop
%%     end.
%%
%% stop() ->
%%     case whereis(mnesia_cluster_boot) of
%%         undefined -> ok;
%%         _         -> await_startup(true)
%%     end,
%%     error_logger:info_msg("Stopping MnesiaCluster~n", []),
%%     stop_apps(?APPS).
%%
%% start_apps(Apps) ->
%%     [application:start(App) || App <- Apps],
%%     ok.
%%
%% stop_apps(Apps) ->
%%     [application:stop(App) || App <- Apps],
%%     ok.
%%
%% await_startup(HaveSeenMnesiaClusterBoot) ->
%%     %% We don't take absence of mnesia_cluster as evidence we've started,
%%     %% since there's a small window before it is registered.
%%     case whereis(mnesia_cluster_boot) of
%%         undefined -> case HaveSeenMnesiaClusterBoot orelse is_running() of
%%                          true  -> ok;
%%                          false -> timer:sleep(100),
%%                                   await_startup(false)
%%                      end;
%%         _         -> timer:sleep(100),
%%                      await_startup(true)
%%     end.
%%
%% is_running() -> is_running(node()).
%%
%% is_running(Node) -> mnesia_cluster_nodes:is_process_running(Node, mnesia_cluster).
%%
%% ensure_application_loaded() ->
%%     %% We end up looking at the mnesia_cluster app's env for HiPE and log
%%     %% handling, so it needs to be loaded. But during the tests, it
%%     %% may end up getting loaded twice, so guard against that.
%%     case application:load(mnesia_cluster) of
%%         ok                                -> ok;
%%         {error, {already_loaded, mnesia_cluster}} -> ok
%%     end.
%%
%%
%% boot_error(Term={error, {timeout_waiting_for_tables, _}}, _Stacktrace) ->
%%     AllNodes = mnesia_cluster_utils:cluster_nodes(all),
%%     {Err, Nodes} =
%%         case AllNodes -- [node()] of
%%             [] -> {"Timeout contacting cluster nodes. Since MnesiaCluster was"
%%                    " shut down forcefully~nit cannot determine which nodes"
%%                    " are timing out.~n", []};
%%             Ns -> {mnesia_cluster_utils:format(
%%                      "Timeout contacting cluster nodes: ~p.~n", [Ns]),
%%                    Ns}
%%         end,
%%     basic_boot_error(Term,
%%                      Err ++ mnesia_cluster_nodes:diagnostics(Nodes) ++ "~n~n", []);
%% boot_error(Reason, Stacktrace) ->
%%     Fmt = "Error description:~n   ~p~n~n",
%%     Args = [Reason],
%%     boot_error(Reason, Fmt, Args, Stacktrace).
%%
%% boot_error(Reason, Fmt, Args, not_available) ->
%%     basic_boot_error(Reason, Fmt, Args);
%% boot_error(Reason, Fmt, Args, Stacktrace) ->
%%     basic_boot_error(Reason, Fmt ++ "Stack trace:~n   ~p~n~n",
%%                      Args ++ [Stacktrace]).
%%
%% basic_boot_error(Reason, Format, Args) ->
%%     io:format("~n~nBOOT FAILED~n===========~n~n" ++ Format, Args),
%%     error_logger:info_msg(Format, Args),
%%     timer:sleep(1000),
%%     exit({?MODULE, failure_during_boot, Reason}).
