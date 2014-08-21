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

-module(mnesia_cluster_table).

-export([create/0, create_local_copy/1, wait_for_replicated/0, wait/1,
         force_load/0, is_present/0, is_empty/0,
         check_schema_integrity/0, clear_ram_only_tables/0]).

-export([test_defs/0]).
-record(test_tab_item, {id, name, description}).

%%----------------------------------------------------------------------------
%% Main interface
%%----------------------------------------------------------------------------

create() ->
    lists:foreach(fun ({Tab, TabDef}) ->
                          TabDef1 = proplists:delete(match, TabDef),
                          case mnesia:create_table(Tab, TabDef1) of
                              {atomic, ok} -> ok;
                              {aborted, Reason} ->
                                  throw({error, {table_creation_failed,
                                                 Tab, TabDef1, Reason}})
                          end
                  end, definitions()),
    ok.

%% The sequence in which we delete the schema and then the other
%% tables is important: if we delete the schema first when moving to
%% RAM mnesia will loudly complain since it doesn't make much sense to
%% do that. But when moving to disc, we need to move the schema first.
create_local_copy(disc) ->
    create_local_copy(schema, disc_copies),
    create_local_copies(disc);
create_local_copy(ram)  ->
    create_local_copies(ram),
    create_local_copy(schema, ram_copies).

wait_for_replicated() ->
    wait([Tab || {Tab, TabDef} <- definitions(),
                 not lists:member({local_content, true}, TabDef)]).

wait(TableNames) ->
    %% We might be in ctl here for offline ops, in which case we can't
    %% get_env() for the emqttd app.
    Timeout = case application:get_env(mnesia_cluster, mnesia_table_loading_timeout) of
                  {ok, T}   -> T;
                  undefined -> 30000
              end,
    case mnesia:wait_for_tables(TableNames, Timeout) of
        ok ->
            ok;
        {timeout, BadTabs} ->
            throw({error, {timeout_waiting_for_tables, BadTabs}});
        {error, Reason} ->
            throw({error, {failed_waiting_for_tables, Reason}})
    end.

force_load() -> [mnesia:force_load_table(T) || T <- names()], ok.

is_present() -> names() -- mnesia:system_info(tables) =:= [].

is_empty() ->
    lists:all(fun (Tab) -> mnesia:dirty_first(Tab) == '$end_of_table' end,
              names()).

check_schema_integrity() ->
    Tables = mnesia:system_info(tables),
    case check(fun (Tab, TabDef) ->
                       case lists:member(Tab, Tables) of
                           false -> {error, {table_missing, Tab}};
                           true  -> check_attributes(Tab, TabDef)
                       end
               end) of
        ok     -> ok = wait(names()),
                  check(fun check_content/2);
        Other  -> Other
    end.

clear_ram_only_tables() ->
    Node = node(),
    lists:foreach(
      fun (TabName) ->
              case lists:member(Node, mnesia:table_info(TabName, ram_copies)) of
                  true  -> {atomic, ok} = mnesia:clear_table(TabName);
                  false -> ok
              end
      end, names()),
    ok.

%%--------------------------------------------------------------------
%% Internal helpers
%%--------------------------------------------------------------------

create_local_copies(Type) ->
    lists:foreach(
      fun ({Tab, TabDef}) ->
              HasDiscCopies     = has_copy_type(TabDef, disc_copies),
              HasDiscOnlyCopies = has_copy_type(TabDef, disc_only_copies),
              LocalTab          = proplists:get_bool(local_content, TabDef),
              StorageType =
                  if
                      Type =:= disc orelse LocalTab ->
                          if
                              HasDiscCopies     -> disc_copies;
                              HasDiscOnlyCopies -> disc_only_copies;
                              true              -> ram_copies
                          end;
                      Type =:= ram ->
                          ram_copies
                  end,
              ok = create_local_copy(Tab, StorageType)
      end, definitions(Type)),
    ok.

create_local_copy(Tab, Type) ->
    StorageType = mnesia:table_info(Tab, storage_type),
    {atomic, ok} =
        if
            StorageType == unknown ->
                mnesia:add_table_copy(Tab, node(), Type);
            StorageType /= Type ->
                mnesia:change_table_copy_type(Tab, node(), Type);
            true -> {atomic, ok}
        end,
    ok.

has_copy_type(TabDef, DiscType) ->
    lists:member(node(), proplists:get_value(DiscType, TabDef, [])).

check_attributes(Tab, TabDef) ->
    {_, ExpAttrs} = proplists:lookup(attributes, TabDef),
    case mnesia:table_info(Tab, attributes) of
        ExpAttrs -> ok;
        Attrs    -> {error, {table_attributes_mismatch, Tab, ExpAttrs, Attrs}}
    end.

check_content(Tab, TabDef) ->
    {_, Match} = proplists:lookup(match, TabDef),
    case mnesia:dirty_first(Tab) of
        '$end_of_table' ->
            ok;
        Key ->
            ObjList = mnesia:dirty_read(Tab, Key),
            MatchComp = ets:match_spec_compile([{Match, [], ['$_']}]),
            case ets:match_spec_run(ObjList, MatchComp) of
                ObjList -> ok;
                _       -> {error, {table_content_invalid, Tab, Match, ObjList}}
            end
    end.

check(Fun) ->
    case [Error || {error, Error} <-
              [Fun(Tab, TabDef) || {Tab, TabDef} <- definitions()]] of
        [] -> ok;
        Errors -> {error, Errors}
    end.

%%--------------------------------------------------------------------
%% Table definitions
%%--------------------------------------------------------------------

names() -> [Tab || {Tab, _} <- definitions()].

%% The tables aren't supposed to be on disk on a ram node
definitions(disc) ->
    definitions();
definitions(ram) ->
    [{Tab, [{disc_copies, []}, {ram_copies, [node()]} |
            proplists:delete(
              ram_copies, proplists:delete(disc_copies, TabDef))]} ||
        {Tab, TabDef} <- definitions()].

definitions() ->
    {ok, {M, F, A}} = application:get_env(mnesia_cluster, table_definition_mod),
    apply(M, F, A).


%% test_definitions
test_defs() ->
    [{test_tab,
      [{record_name, test_tab_item},
       {attributes, record_info(fields, test_tab_item)},
       {disc_copies, [node()]},
       {match, #test_tab_item{_='_'}}]}].
