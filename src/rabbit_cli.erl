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

-module(rabbit_cli).
-include("rabbit_cli.hrl").

-export([main/3, start_distribution/0, start_distribution/1,
         parse_arguments/4, rpc_call/4]).

%%----------------------------------------------------------------------------

-ifdef(use_specs).

-type(optdef() :: flag | {option, string()}).
-type(parse_result() :: {'ok', {atom(), [{string(), string()}], [string()]}} |
                        'no_command').


-spec(main/3 :: (fun (([string()], string()) -> parse_result()),
                     fun ((atom(), atom(), [any()], [any()]) -> any()),
                         atom()) -> no_return()).
-spec(start_distribution/0 :: () -> {'ok', pid()} | {'error', any()}).
-spec(start_distribution/1 :: (string()) -> {'ok', pid()} | {'error', any()}).
-spec(usage/1 :: (atom()) -> no_return()).
-spec(parse_arguments/4 ::
        ([{atom(), [{string(), optdef()}]} | atom()],
         [{string(), optdef()}], string(), [string()]) -> parse_result()).
-spec(rpc_call/4 :: (node(), atom(), atom(), [any()]) -> any()).

-endif.

%%----------------------------------------------------------------------------
%% RabbitMQ系统客户端主入口
main(ParseFun, DoFun, UsageMod) ->
	error_logger:tty(false),
	start_distribution(),
	{ok, [[NodeStr | _] | _]} = init:get_argument(nodename),
	%% 解析出命令行参数(Command：为当前操作的命令名字，Opts：有操作的节点名字已经是否进行打印的标识，Args：表示当前命令带有的额外参数)
	{Command, Opts, Args} =
		case ParseFun(init:get_plain_arguments(), NodeStr) of
			{ok, Res}  -> Res;
			no_command -> print_error("could not recognise command", []),
						  usage(UsageMod)
		end,
	Node = proplists:get_value(?NODE_OPT, Opts),
	PrintInvalidCommandError =
		fun () ->
				 print_error("invalid command '~s'",
							 [string:join([atom_to_list(Command) | Args], " ")])
		end,
	
	%% The reason we don't use a try/catch here is that rpc:call turns
	%% thrown errors into normal return values
	case catch DoFun(Command, Node, Args, Opts) of
		ok ->
			rabbit_misc:quit(0);
		{'EXIT', {function_clause, [{?MODULE, action, _}    | _]}} -> %% < R15
			PrintInvalidCommandError(),
			usage(UsageMod);
		{'EXIT', {function_clause, [{?MODULE, action, _, _} | _]}} -> %% >= R15
			PrintInvalidCommandError(),
			usage(UsageMod);
		{error, {missing_dependencies, Missing, Blame}} ->
			print_error("dependent plugins ~p not found; used by ~p.",
						[Missing, Blame]),
			rabbit_misc:quit(2);
		{'EXIT', {badarg, _}} ->
			print_error("invalid parameter: ~p", [Args]),
			usage(UsageMod);
		{error, {Problem, Reason}} when is_atom(Problem), is_binary(Reason) ->
			%% We handle this common case specially to avoid ~p since
			%% that has i18n issues
			print_error("~s: ~s", [Problem, Reason]),
			rabbit_misc:quit(2);
		{error, Reason} ->
			print_error("~p", [Reason]),
			rabbit_misc:quit(2);
		{error_string, Reason} ->
			print_error("~s", [Reason]),
			rabbit_misc:quit(2);
		{badrpc, {'EXIT', Reason}} ->
			print_error("~p", [Reason]),
			rabbit_misc:quit(2);
		{badrpc, Reason} ->
			print_error("unable to connect to node ~w: ~w", [Node, Reason]),
			print_badrpc_diagnostics([Node]),
			rabbit_misc:quit(2);
		{badrpc_multi, Reason, Nodes} ->
			print_error("unable to connect to nodes ~p: ~w", [Nodes, Reason]),
			print_badrpc_diagnostics(Nodes),
			rabbit_misc:quit(2);
		Other ->
			print_error("~p", [Other]),
			rabbit_misc:quit(2)
	end.


start_distribution() ->
	%% os:getpid()得到当前虚拟机在操作系统中的进程id号
	start_distribution(list_to_atom(
						 rabbit_misc:format("rabbitmq-cli-~s", [os:getpid()]))).


start_distribution(Name) ->
	rabbit_nodes:ensure_epmd(),
	%% 通过启动net_kernel和其他必要的过程变成一个非分布式节点到分布式节点。
	net_kernel:start([Name, name_type()]).


name_type() ->
	case os:getenv("RABBITMQ_USE_LONGNAME") of
		"true" -> longnames;
		_      -> shortnames
	end.


usage(Mod) ->
	io:format("~s", [Mod:usage()]),
	rabbit_misc:quit(1).

%%----------------------------------------------------------------------------
%% 解析RabbitMQ系统客户端传入的命令
parse_arguments(Commands, GlobalDefs, NodeOpt, CmdLine) ->
	case parse_arguments(Commands, GlobalDefs, CmdLine) of
		{ok, {Cmd, Opts0, Args}} ->
			Opts = [case K of
						NodeOpt -> {NodeOpt, rabbit_nodes:make(V)};
						_       -> {K, V}
					end || {K, V} <- Opts0],
			{ok, {Cmd, Opts, Args}};
		E ->
			E
	end.

%% Takes:
%%    * A list of [{atom(), [{string(), optdef()]} | atom()], where the atom()s
%%      are the accepted commands and the optional [string()] is the list of
%%      accepted options for that command
%%    * A list [{string(), optdef()}] of options valid for all commands
%%    * The list of arguments given by the user
%%
%% Returns either {ok, {atom(), [{string(), string()}], [string()]} which are
%% respectively the command, the key-value pairs of the options and the leftover
%% arguments; or no_command if no command could be parsed.
%% 对RabbitMQ系统支持的所有命令循环一遍(取得Cmd命令，Opts配置，Args参数)
parse_arguments(Commands, GlobalDefs, As) ->
	lists:foldl(maybe_process_opts(GlobalDefs, As), no_command, Commands).


maybe_process_opts(GDefs, As) ->
	fun({C, Os}, no_command) ->
			%% 此处命令需要额外的参数配置，则将全局的配置参数和命令特殊需要的参数合并组装成字典
			process_opts(atom_to_list(C), dict:from_list(GDefs ++ Os), As);
	   (C, no_command) ->
			(maybe_process_opts(GDefs, As))({C, []}, no_command);
	   (_, {ok, Res}) ->
			{ok, Res}
	end.


%% C		：	表示命令名字
%% Defs		：	表示命令必要的参数列表
%% As0		：	表示客户端输入的必要信息
process_opts(C, Defs, As0) ->
	KVs0 = dict:map(fun (_, flag)        -> false;
					   (_, {option, V}) -> V
					end, Defs),
	process_opts(Defs, C, As0, not_found, KVs0, []).

%% Consume flags/options until you find the correct command. If there are no
%% arguments or the first argument is not the command we're expecting, fail.
%% Arguments to this are: definitions, cmd we're looking for, args we
%% haven't parsed, whether we have found the cmd, options we've found,
%% plain args we've found.
process_opts(_Defs, C, [], found, KVs, Outs) ->
	%% 已经找到命令参数,将dict中的参数转化为列表
	{ok, {list_to_atom(C), dict:to_list(KVs), lists:reverse(Outs)}};
process_opts(_Defs, _C, [], not_found, _, _) ->
	no_command;
process_opts(Defs, C, [A | As], Found, KVs, Outs) ->
	OptType = case dict:find(A, Defs) of
				  error             -> none;
				  {ok, flag}        -> flag;
				  {ok, {option, _}} -> option
			  end,
	case {OptType, C, Found} of
		%% 命令行中的标识设置(比如说-q表示将不会打印相关信息等)
		{flag, _, _}     ->
			process_opts(
			  Defs, C, As, Found, dict:store(A, true, KVs),
			  Outs);
		%% 命令行中的参数设置(比如说-n 后面跟着操作的节点名字等参数)
		{option, _, _}   -> case As of
								[]        -> no_command;
								[V | As1] -> process_opts(
											   Defs, C, As1, Found,
											   %% 存储命令行参数
											   dict:store(A, V, KVs), Outs)
							end;
		%% 已经得到当前执行的命令名字，输入的命令和当前要匹配的命令名字一样，则找到命令
		{none, A, _}     -> process_opts(Defs, C, As, found, KVs, Outs);
		%% 在得到当前执行的命令名字后其他变量称为变量参数，即得到命令相关信息
		{none, _, found} -> process_opts(Defs, C, As, found, KVs, [A | Outs]);
		{none, _, _}     -> no_command
	end.

%%----------------------------------------------------------------------------

fmt_stderr(Format, Args) -> rabbit_misc:format_stderr(Format ++ "~n", Args).


print_error(Format, Args) -> fmt_stderr("Error: " ++ Format, Args).


print_badrpc_diagnostics(Nodes) ->
	fmt_stderr(rabbit_nodes:diagnostics(Nodes), []).

%% If the server we are talking to has non-standard net_ticktime, and
%% our connection lasts a while, we could get disconnected because of
%% a timeout unless we set our ticktime to be the same. So let's do
%% that.
rpc_call(Node, Mod, Fun, Args) ->
	case rpc:call(Node, net_kernel, get_net_ticktime, [], ?RPC_TIMEOUT) of
		{badrpc, _} = E -> E;
		Time            -> net_kernel:set_net_ticktime(Time, 0),
						   rpc:call(Node, Mod, Fun, Args, ?RPC_TIMEOUT)
	end.
