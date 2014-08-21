-module(mnesia_cluster_app_watcher).
-behaviour(gen_server).
-export([start_link/1]).
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-define(INTERVALL, 500).

start_link(App) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [App], []).

init([App]) ->
    {ok, {App, is_app_alive(App)}}.

handle_call(_Req, _From, State) ->
    {reply, {error, not_implemented}, State}.

handle_cast(_Req, State) ->
    {noreply, State}.

handle_info(watch_app, {App, _}) ->
    {noreply, {App, is_app_alive(App)}};
handle_info({'DOWN', _, process, _Pid, _Reason}, {App, _}) ->
    monitor_callbacks(node(), on_node_down),
    {noreply, {App, is_app_alive(App)}}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

is_app_alive(App) ->
    case is_registered_process_alive(App) of
        false ->
            erlang:send_after(?INTERVALL, self(), watch_app),
            undefined;
        {true, Pid} ->
            case is_registered_process_alive(mnesia_cluster_monitor) of
                false ->
                    erlang:send_after(?INTERVALL, self(), watch_app),
                    undefined;
                {true, _} ->
                    mnesia_cluster_monitor:notify_node_up(),
                    monitor_callbacks(node(), on_node_up),
                    monitor(process, Pid);
                _ ->
                    erlang:send_after(?INTERVALL, self(), watch_app),
                    undefined
            end;
        _ ->
            erlang:send_after(?INTERVALL, self(), watch_app),
            undefined
    end.

is_registered_process_alive(Name) ->
    case whereis(Name) of
        undefined ->
            false;
        Pid ->
            {is_process_alive(Pid), Pid}
    end.

monitor_callbacks(Node, Fun) ->
    {ok, Callbacks} = application:get_env(mnesia_cluster, cluster_monitor_callbacks),
    [apply(M, Fun, [Node]) || M <- Callbacks],
    ok.
