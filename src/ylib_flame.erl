%%% ---------------------------
%% @doc 生成火焰图工具，注意性能影响，生产环境慎用
%%% ---------------------------
-module(ylib_flame).

-export([
    start/1,
    stop/0,
    stop/1,
    apply/1
]).
-export([
    tracer_loop/3
]).

-define(MSG_PRINT(__Format, __Args), io:format(__Format, __Args)).
-define(TIPS_PRINT(__Format, __Args, __Opts), case __Opts of #{quite := false} -> ?MSG_PRINT(__Format, __Args); _ -> ok end).
-define(DEBUG_PRINT(__Format, __Args, __Opts), case __Opts of #{quite := false, debug := true} -> io:format(__Format, __Args); _ -> ok end).

-define(SRC_TYPE_TRACE, trace).
-define(SRC_TYPE_ETS, ets).
-define(SRC_TYPE_MSG, msg).

-define(OUT_TYPE_OUT, out).
-define(OUT_TYPE_ETS, ets).
-define(OUT_TYPE_MSG, msg).

-define(FLAME_TRACE_NAME, ylib_flame_tracer).
-define(FLAME_ANALYSE_NAME, ylib_flame_analyser).
-define(FLAME_DATA_ETS, ylib_flame_data_ets).

-define(DEFAULT_OPTS,
    begin
        {_, __GLPid} = process_info(erlang:self(), group_leader),
        #{
            src_type => ?SRC_TYPE_TRACE, %% trace|msg|ets 默认是trace获得消息,msg和ets表示从其它中间文件处理
            src_value => all, %% src_type = msg和ets时为filename，为trace时，是pid或者atom
            out_type => ?OUT_TYPE_OUT, %% out|msg|ets, out是直接处理后输出，ets是输出原始数据，msg是输出可视数据
            out_file => "",
            auto_pname => true,  %% 尽量把进程pid转为进程名

            gen_call => true, %% 是否把使用gen call时的等待时间计算进去
            proc_names => #{}, %% 默认为空即可
            link_pid => erlang:self(), %% 链接进程，该进程挂了则退出trace
            quite => false, %% 不输出额外信息
            debug => false, %% 是否输出调试信息
            auto_file => true,
            protect => {200, 50000} %% 每M个消息检查一次，如果未处理的消息超过N则停下
        }
    end).

%% PidOrProcName | [PidOrProcName] | FileName | processes | existing_processes | new_processes，除了指定Pid，其它的大概率会挂
start(Pid) when erlang:is_atom(Pid) orelse erlang:is_pid(Pid) ->
    start(#{src_type => ?SRC_TYPE_TRACE, src_value => Pid});
start([Pid|PidList]) when erlang:is_atom(Pid) orelse erlang:is_pid(Pid) ->
    Res = start(#{src_type => ?SRC_TYPE_TRACE, src_value => Pid}),
    [ start(T) || T <- PidList],
    Res;
start(File) when erlang:is_binary(File) ->
    start(erlang:binary_to_list(File));

start(File) when erlang:is_list(File) ->
    case string:lowercase(filename:extension(File)) of
        ".ets" -> start(#{src_type => ?SRC_TYPE_ETS, src_value => File});
        ".msg" -> start(#{src_type => ?SRC_TYPE_MSG, src_value => File})
    end;

start({Pid, Tar}) ->
    start(#{src_type => trace, src_value => Pid, out_type => Tar});
start({Pid, Tar, Interval}) ->
    Res = start(#{src_type => trace, src_value => Pid, out_type => Tar}),
    timer:sleep(Interval),
    ok = stop(),
    Res;

start(Opts) when erlang:is_map(Opts) ->
    start2(fix_opts(maps:merge(?DEFAULT_OPTS, Opts))).

start2(#{src_type := ?SRC_TYPE_TRACE} = Opts) ->
    ?DEBUG_PRINT("opts:~w~n", [Opts], Opts),
    Target = maps:get(src_value, Opts),
    {ok, Tracer} = start_tracer(Opts),
    add_opts_list(Opts),
    MatchSpec = [{'_', [], [{message, {{cp, {caller}}}}]}],
    erlang:trace_pattern(on_load, MatchSpec, [local]),
    erlang:trace_pattern({'_', '_', '_'}, MatchSpec, [local]),
    erlang:trace(Target, true, [{tracer, Tracer} | [call, arity, return_to, monotonic_timestamp, running, set_on_spawn] ]),
    {ok, Tracer};
start2(#{src_type := SrcType} = Opts) when SrcType=:=?SRC_TYPE_ETS orelse SrcType=:=?SRC_TYPE_MSG ->
    Task = spawn_task(fun()-> erlang:register(?FLAME_ANALYSE_NAME, erlang:self()), start_analyse(Opts) end),
    ?TIPS_PRINT("task:~w~n", [Task], Opts),
    wait_task(Task).

stop() ->
    stop(ok).
stop(Reason) ->
    erlang:trace(erlang:self(), false, [all]),
    case whereis(?FLAME_TRACE_NAME) of
        TPid when is_pid(TPid) ->
            do_stop(TPid, Reason);
        _->
            {error, not_exist}
    end.

do_stop(TPid, Reason) ->
    stop_all_trace(),
    case erlang:self() =:= TPid of
        true ->
            erlang:send(TPid, {stop, Reason});
        _ ->
            MRef = erlang:monitor(process, TPid),
            erlang:send(TPid, {stop, Reason}),
            receive
                {'DOWN', MRef, _, _, _} -> ok
            end
    end.


apply(Func) ->
    {ok, _Trace} = start(#{src_type => ?SRC_TYPE_TRACE, src_value => erlang:self()}),
    Res = apply_fun(Func),
    stop(ok),
    Res.


start_tracer(Opts) ->
    case whereis(?FLAME_TRACE_NAME) of
        TPid when is_pid(TPid) ->
            {ok, TPid};
        _->
            {ok, TPid} = start_tracer2(Opts),
            {ok, TPid}
    end.

start_tracer2(Opts) ->
    Self = erlang:self(),
    TPid = erlang:spawn_opt(fun() ->
                                case catch tracer(Self, Opts) of
                                    ok -> ok;
                                    {ok, Res} -> ?TIPS_PRINT("done:~w~n", [Res], Opts);
                                    _Err -> ?MSG_PRINT("err:~w~n", [_Err])
                                end
                            end, [{priority, max}]),
    receive
        {ok, Self} -> {ok, TPid}
    after 1000 -> erlang:throw({error, TPid})
    end.

tracer(P, Opts) ->
    Ets = create_analyse_ets(),
    create_data_ets(),
    true = erlang:register(?FLAME_TRACE_NAME, self()),
    erlang:process_flag(trap_exit, true),
    %% erlang:process_flag(message_queue_data, off_heap),
    LinkPid = maps:get(link_pid, Opts),
    link(LinkPid),
    ?TIPS_PRINT("trace:~w~n",[Ets], Opts),
    erlang:send(P, {ok, P}),
    ?MODULE:tracer_loop(Opts#{ets => Ets}, LinkPid, 1).
tracer_loop(Opts, LinkPid, Count) ->
    receive
        {'EXIT', LinkPid, _}=_Err ->
            ?DEBUG_PRINT("~w", [_Err], Opts),
            stop_all_trace(),
            dump_trace_result(Opts),
            erlang:throw({error, _Err});
        {stop, Reason} ->
            stop_all_trace(),
            dump_trace_result(Opts),
            erlang:throw(Reason);
        Msg ->
            trace_handle(Msg, Opts)
    end,
    case erlang:get(stopping) =:= undefined andalso maps:get(protect, Opts) of
        {CNum, MNum} when Count > CNum ->
            case erlang:process_info(self(), message_queue_len) of
                {message_queue_len, AbsNum} when AbsNum>=MNum ->
                    %% 累积超过阈值，处理完当前累积的，就不再处理了
                    erlang:put(stopping, AbsNum),
                    do_stop(erlang:self(), {error, {protect, AbsNum}}),
                    ?TIPS_PRINT("trigger protect ~w，please wait a moment~n", [AbsNum], Opts);
                _ ->
                    ok
            end,
            ?MODULE:tracer_loop(Opts, LinkPid, 1);
        _ ->
            ?MODULE:tracer_loop(Opts, LinkPid, Count+1)
    end.


stop_all_trace() ->
    catch erlang:trace_pattern({'_', '_', '_'}, false, [local]),
    [ catch erlang:trace(Target, false, [all]) || #{src_type := ?SRC_TYPE_TRACE, src_value := Target } <- get_all_list()],
    ok.
dump_trace_result(Opts) ->
    flush_all_msg(),
    dump_to_file(Opts),
    ok.


trace_handle(Term, #{ets := Ets, out_type := ?OUT_TYPE_OUT, gen_call := IsCalc}) when erlang:is_tuple(Term) ->
    trace_ts = element(1, Term),
    From = element(2, Term),
    CurTs = erlang:element(erlang:tuple_size(Term), Term),
    case erlang:get({stack, From}) of
        undefined -> LastUs = undefined, Stack = [];
        {LastUs, Stack} -> ok
    end,
    NewStack = trace_stack_hande(Term, From, Stack, LastUs, Ets, IsCalc),
    erlang:put({stack, From}, {CurTs, NewStack}),
    ok;
trace_handle(Term, #{ets := Ets, out_type := ?OUT_TYPE_MSG}) when erlang:is_tuple(Term) ->
    Index = new_index(),
    ets:insert(Ets, {Index, Term}),
    ok;
trace_handle(Term, #{ets := Ets, out_type := ?OUT_TYPE_ETS}) when erlang:is_tuple(Term) ->
    Index = new_index(),
    ets:insert(Ets, {Index, Term}),
    ok;
trace_handle(Term, Ets) ->
    ?MSG_PRINT("~w~n", [{Term,Ets}]).

dump_to_file(#{ets := Ets, out_type := ?OUT_TYPE_MSG, proc_names :=NameMap, auto_pname := AutoPName} = Opts) ->
    OutputFile = get_dump_filename(Opts),
    ?TIPS_PRINT("writing:~ts, ~w~n", [OutputFile, ets:info(Ets, size)], Opts),
    {ok, Fd} = file:open(OutputFile, [write, sync]),
    case AutoPName of
        true -> dump_msg_file(Fd, Ets, 1, NameMap);
        _ -> dump_msg_file(Fd, Ets, 1)
    end,
    file:close(Fd),
    ?TIPS_PRINT("run ~ts:start(\"~ts\"). to dump out file~n", [?MODULE, OutputFile], Opts),
    ok;
dump_to_file(#{ets := Ets, out_type := ?OUT_TYPE_ETS, proc_names :=NameMap, auto_pname := AutoPName} = Opts) ->
    OutputFile = get_dump_filename(Opts),
    ?TIPS_PRINT("writing:~ts, ~w~n", [OutputFile, ets:info(Ets, size)], Opts),
    case AutoPName of
        true -> dump_ets_file(OutputFile, Ets, 1, NameMap);
        _ -> dump_ets_file(OutputFile, Ets, 1)
    end,
    ?TIPS_PRINT("run ~ts:start(\"~ts\"). to dump out file~n", [?MODULE, OutputFile], Opts),
    ok;
dump_to_file(#{ets := Ets, out_type := ?OUT_TYPE_OUT, proc_names :=NameMap, auto_pname := AutoPName} = Opts) ->
    OutputFile = get_dump_filename(Opts),
    ?TIPS_PRINT("writing:~ts, ~w~n", [OutputFile, ets:info(Ets, size)], Opts),
    {ok, Fd} = file:open(OutputFile, [write, sync]),
    case AutoPName of
        true -> dump_out_file(Fd, Ets, ets:first(Ets), NameMap, Opts);
        false -> dump_out_file(Fd, Ets, ets:first(Ets), Opts)
    end,
    file:close(Fd),
    ?TIPS_PRINT("run script to dump svg~n", [], Opts),
    ?TIPS_PRINT("./stack_to_flame.sh  ~ts~n", [OutputFile], Opts),
    ok.

get_dump_filename(#{out_file := OutputFile0, auto_file := IsAuto, out_type := TarExt}) ->
    {ok, CurPath} = file:get_cwd(),
    {{Y,M,D}, {HH,MM,SS}} = erlang:localtime(),
    OutputFile =
        case OutputFile0 of
            "" -> io_lib:format("stacks_~4..0B_~2..0B_~2..0B_~2..0B_~2..0B_~2..0B.~ts", [Y,M,D,HH,MM,SS,TarExt]);
            _ -> filename:basename(filename:rootname(OutputFile0)) ++ "." ++ erlang:atom_to_list(TarExt)
        end,
    OutputFile2 = filename:join([CurPath,OutputFile]),
    NewOutputFile =
        case IsAuto of
            true -> next_file(OutputFile2);
            _ -> OutputFile2
        end,
    NewOutputFile.

next_file(OutputFile) ->
    case filelib:is_file(OutputFile) of
        true -> next_file(OutputFile ++ ".", 1);
        _ -> OutputFile
    end.
next_file(OutputFileBase, Index) ->
    OutputFile = OutputFileBase ++ erlang:integer_to_list(Index),
    case filelib:is_file(OutputFile) of
        true -> next_file(OutputFileBase, Index+1);
        false -> OutputFile
    end.

create_analyse_ets() ->
    ets:new(tmp_flame, [ordered_set]).
create_data_ets() ->
    ets:new(?FLAME_DATA_ETS, [named_table, set, public]).

insert_run_time(_Ets, _From, [], _Us, _Ts) ->
    ok;
insert_run_time(_Ets, _From, _Stack, undefined, _Ts) ->
    ok;
insert_run_time(Ets, From, Stack, Us, Ts) ->
    Diff = Ts - Us,
    case erlang:get({last_stack, From}) of
        undefined ->
            Index = 1,
            ets:insert(Ets, {{From, Index}, {Stack, Diff}}),
            erlang:put({last_stack, From}, {Index, Stack, Diff});
        {Index, LastStack, LastNum} ->
            case Stack=:=LastStack of
                true ->
                    ets:insert(Ets, {{From, Index}, {Stack, LastNum+Diff}}),
                    erlang:put({last_stack, From}, {Index, Stack, LastNum+Diff});
                false ->
                    ets:insert(Ets, {{From, Index+1}, {Stack, Diff}}),
                    erlang:put({last_stack, From}, {Index+1, Stack, Diff})
            end
    end,
    ok.
trace_stack_hande({trace_ts, _Ps, call, MFA, {cp, {_,_,_} = CallerMFA}, Ts}, From, [], Us, Ets, _IsCalc) ->
    insert_run_time(Ets, From, [], Us, Ts),
    [MFA, CallerMFA];

trace_stack_hande({trace_ts, _Ps, call, MFA, {cp, undefined}, Ts}, From, [], Us, Ets, _IsCalc) ->
    insert_run_time(Ets, From, [], Us, Ts),
    [MFA];

trace_stack_hande({trace_ts, _Ps, call, MFA, {cp, undefined}, Ts}, From, [MFA|_] = Stack, Us, Ets, _IsCalc) ->
    insert_run_time(Ets, From, Stack, Us, Ts),
    Stack;

trace_stack_hande({trace_ts, _Ps, call, MFA, {cp, undefined}, Ts}, From, Stack, Us, Ets, _IsCalc) ->
    insert_run_time(Ets, From, Stack, Us, Ts),
    [MFA | Stack];

trace_stack_hande({trace_ts, _Ps, call, MFA, {cp, MFA}, Ts}, From, [MFA|_]=Stack, Us, Ets, _IsCalc) ->
    insert_run_time(Ets, From, Stack, Us, Ts),
    Stack; % collapse tail recursion

trace_stack_hande({trace_ts, _Ps, call, MFA, {cp, CpMFA}, Ts}, From, [CpMFA|_]=Stack, Us, Ets, _IsCalc) ->
    insert_run_time(Ets, From, Stack, Us, Ts),
    [MFA|Stack];

trace_stack_hande({trace_ts, _Ps, call, _MFA, {cp, _}, Ts} = TraceTs, From, [_|StackRest]=Stack, Us, Ets, _IsCalc) ->
    insert_run_time(Ets, From, Stack, Us, Ts),
    trace_stack_hande(TraceTs, From, StackRest, Us, Ets, _IsCalc);

trace_stack_hande({trace_ts, _Ps, return_to, MFA, Ts}, From, [Current, MFA|Stack], Us, Ets, _IsCalc) ->
    insert_run_time(Ets, From, [Current,MFA|Stack], Us, Ts),
    [MFA|Stack]; % do not try to traverse stack down because we've already collapsed it

trace_stack_hande({trace_ts, _Ps, return_to, undefined, Ts}, From, Stack, Us, Ets, _IsCalc) ->
    insert_run_time(Ets, From, Stack, Us, Ts),
    Stack;

trace_stack_hande({trace_ts, _Ps, return_to, _, Ts}, From, Stack, Us, Ets, _IsCalc) ->
    insert_run_time(Ets, From, Stack, Us, Ts),
    Stack;

trace_stack_hande({trace_ts, _Ps, in, _MFA, Ts}, From, [gen_receive|Stack], Us, Ets, _IsCalc) ->
    insert_run_time(Ets, From, ['-'|Stack], Us, Ts),
    Stack;

trace_stack_hande({trace_ts, _Ps, in, _MFA, _Ts}, _From, Stack, _Us, _Ets, _IsCalc) ->
    Stack;
trace_stack_hande({trace_ts, _Ps, out, {gen,do_call,4}, Ts}, From, Stack, Us, Ets, true) ->
    insert_run_time(Ets, From, Stack, Us, Ts),
    [gen_receive|Stack];
trace_stack_hande({trace_ts, _Ps, out, _MFA, Ts}, From, Stack, Us, Ets, _IsCalc) ->
    insert_run_time(Ets, From, Stack, Us, Ts),
    Stack;

trace_stack_hande(TraceTs, _From, Stack, _Us, _Ets, _IsCalc) ->
    ?MSG_PRINT("trace_stack_hande: unknown trace: ~p~n", [TraceTs]),
    Stack.



start_analyse(Opts0) ->
    Opts = Opts0#{ets => create_analyse_ets()},
    ?DEBUG_PRINT("opts:~w~n", [Opts], Opts),
    case Opts of
        #{src_type := ?SRC_TYPE_ETS} -> start_analyse_ets(Opts);
        #{src_type := ?SRC_TYPE_MSG} -> start_analyse_msg(Opts)
    end.
start_analyse_ets(#{src_value := SrcFile} = Opts) ->
    {ok, Tab} = ets:file2tab(SrcFile),
    ?TIPS_PRINT("analyse:~w(~w)~n", [Tab, erlang:term_to_binary(Tab)], Opts),
    [{_, ProcNames}] = ets:take(Tab, proc_names),
    NewOpts = Opts#{proc_names := ProcNames, out_type => ?OUT_TYPE_OUT},
    analyse_ets_loop(Tab, 1, ets:info(Tab, size), NewOpts),
    dump_to_file(NewOpts),
    ok.
analyse_ets_loop(Tab, Index, Total, Opts) ->
    case ets:lookup(Tab, Index) of
        [{_, Term}] ->
            trace_handle(Term, Opts),
            progress_print(Index, Total, Opts),
            analyse_ets_loop(Tab, Index+1, Total, Opts);
        [] ->
            case Index =:= Total + 1 of
                true -> ok;
                false -> ?MSG_PRINT("size error:~w, skip ~w~n", [Total, Total-Index])
            end,
            ok
    end.
start_analyse_msg(#{src_value := SrcFile} = Opts) ->
    {ok, List} = file:consult(SrcFile),
    NewOpts = Opts#{out_type => ?OUT_TYPE_OUT},
    analyse_msg_loop(List, 1, erlang:length(List), NewOpts),
    dump_to_file(NewOpts),
    ok.
analyse_msg_loop([Term|List], Index, Total, Opts) ->
    trace_handle(Term, Opts),
    progress_print(Index, Total, Opts),
    analyse_msg_loop(List, Index+1, Total, Opts);
analyse_msg_loop([], Index, Total, _Opts) ->
    case Index =:= Total + 1 of
        true -> ok;
        false -> ?MSG_PRINT("size error:~w, skip ~w~n", [Total, Total-Index])
    end,
    ok.

progress_print(Total, Total, Opts) ->
    ?DEBUG_PRINT("100%~n", [], Opts);
progress_print(Index, Total, Opts) ->
    case Index rem 1000 =:= 0 of
        true -> ?DEBUG_PRINT("~.2f%~n", [Index*100/Total], Opts);
        _ -> ok
    end.

dump_msg_file(Fd, Ets, Index) ->
    case ets:lookup(Ets, Index) of
        [{_, Term}] ->
            ProcName = pid_to_list(element(2, Term)),
            file:write(Fd, io_lib:format("~999999999p.~n", [erlang:setelement(2, Term, ProcName)])),
            dump_msg_file(Fd, Ets, Index+1);
        [] ->
            Index = ets:info(Ets, size) + 1,
            ok
    end.
dump_msg_file(Fd, Ets, Index, NameMap) ->
    case ets:lookup(Ets, Index) of
        [{_, Term}] ->
            From = element(2, Term),
            {ProcName, NewNameMap} = get_proc_name(From, NameMap),
            file:write(Fd, io_lib:format("~999999999p.~n", [erlang:setelement(2, Term, ProcName)])),
            dump_msg_file(Fd, Ets, Index+1, NewNameMap);
        [] ->
            Index = ets:info(Ets, size) + 1,
            ok
    end.

dump_ets_file(OutputFile, Ets, Index, NameMap) ->
    case ets:lookup(Ets, Index) of
        [{_, Term}] ->
            From = element(2, Term),
            {_ProcName, NewNameMap} = get_proc_name(From, NameMap),
            dump_ets_file(OutputFile, Ets, Index+1, NewNameMap);
        [] ->
            Index = ets:info(Ets, size) + 1,
            ets:insert(Ets, {proc_names, NameMap}),
            ets:tab2file(Ets, OutputFile, [{sync, true}]),
            ok
    end.
dump_ets_file(OutputFile, Ets, Index) ->
    Index = ets:info(Ets, size) + 1,
    ets:insert(Ets, {proc_names, #{}}),
    ets:tab2file(Ets, OutputFile, [{sync, true}]),
    ok.

dump_out_file(_Fd, _Ets, '$end_of_table', _NameMap, Opts) ->
    ?TIPS_PRINT("~n",[],Opts),
    ok;
dump_out_file(Fd, Ets, Key, NameMap, Opts) ->
    [{{Pid, _Index}, {S, Num}}] = ets:take(Ets, Key),
    {ProcName, NewNameMap} = get_proc_name(Pid, NameMap),
    Bytes = iolist_to_binary([ProcName, <<";">>, stack_collapse(lists:reverse(S)), <<" ">>, erlang:integer_to_binary(Num), <<"\n">>]),
    file:write(Fd, Bytes),
    dump_out_file(Fd, Ets, ets:first(Ets), NewNameMap, Opts).

dump_out_file(_Fd, _Ets, '$end_of_table', Opts) ->
    ?TIPS_PRINT("~n",[],Opts),
    ok;
dump_out_file(Fd, Ets, Key, Opts) ->
    [{{Pid, _Index}, {S, Num}}] = ets:take(Ets, Key),
    ProcName = pid_to_list(Pid),
    Bytes = iolist_to_binary([ProcName, <<";">>, stack_collapse(lists:reverse(S)), <<" ">>, erlang:integer_to_binary(Num), <<"\n">>]),
    file:write(Fd, Bytes),
    dump_out_file(Fd, Ets, ets:first(Ets), Opts).

get_proc_name(Pid, NameMap) ->
    case NameMap of
        #{Pid := PName} -> {PName, NameMap};
        _ ->
            PName = get_proc_name2(Pid),
            {PName, NameMap#{ Pid => PName}}
    end.
get_proc_name2(Pid) when erlang:is_pid(Pid) ->
    case catch erlang:node(Pid) of
        Node when erlang:is_atom(Node) ->
            case rpc:call(Node, erlang, process_info, [Pid, registered_name]) of
                {registered_name, Name} -> erlang:atom_to_list(Name);
                [] -> pid_to_list(Pid);
                undefined -> pid_to_list(Pid)
            end;
        _ ->
            pid_to_list(Pid)
    end;
get_proc_name2(Pid) when erlang:is_list(Pid) ->
    Pid.

stack_collapse(Stack) ->
    intercalate(";", [entry_to_iolist(S) || S <- Stack]).
entry_to_iolist({M, F, A}) ->
    [atom_to_binary(M, utf8), <<":">>, atom_to_binary(F, utf8), <<"/">>, integer_to_list(A)];
entry_to_iolist(A) when is_atom(A) ->
    [atom_to_binary(A, utf8)].
intercalate(Sep, Xs) -> lists:concat(intersperse(Sep, Xs)).
intersperse(_, []) -> [];
intersperse(_, [X]) -> [X];
intersperse(Sep, [X | Xs]) -> [X, Sep | intersperse(Sep, Xs)].


flush_all_msg() ->
    receive
        _Msg ->
            flush_all_msg()
    after 100 ->
        ok
    end.
-compile({inline, [apply_fun/1]}).
apply_fun(Func) ->
    case Func of
        {func, F, A} ->
            erlang:apply(F, A);
        {func, M, F, A} ->
            erlang:apply(M, F, A);
        {func, Function} when erlang:is_function(Function) ->
            Function();
        {F, A} ->
            erlang:apply(F, A);
        {M, F, A} ->
            erlang:apply(M, F, A);
        {Function} when erlang:is_function(Function) ->
            Function();
        Function when erlang:is_function(Function) ->
            Function()
    end.

fix_opts(#{src_type := ?SRC_TYPE_TRACE} = Opts) ->
    %% 把进程名转为进程pid
    case maps:get(src_value, Opts) of
        processes -> Opts;
        existing_processes -> Opts;
        new_processes -> Opts;
        all -> Opts#{src_value := processes};
        existing -> Opts#{src_value := existing_processes};
        Pid when erlang:is_pid(Pid) -> Opts;
        Atom when erlang:is_atom(Atom) -> Opts#{src_value => erlang:whereis(Atom)}
    end;
fix_opts(#{src_type := ?SRC_TYPE_ETS, src_value := SrcFile, out_file:= ""} = Opts) ->
    %% 结果转换的，最好使用原名
    OutFile = filename:basename(filename:rootname(SrcFile)),
    Opts#{out_file => OutFile};
fix_opts(#{src_type := ?SRC_TYPE_MSG, src_value := SrcFile, out_file:= ""} = Opts) ->
    %% 结果转换的，最好使用原名
    OutFile = filename:basename(filename:rootname(SrcFile)),
    Opts#{out_file => OutFile};
fix_opts(Opts) ->
    Opts.

spawn_task(Func) ->
    Parent = self(),
    {Pid, MRef} =
        erlang:spawn_monitor(
            fun() ->
                Res = apply_fun(Func),
                erlang:send(Parent, {ok, self(), Res})
            end),
    {Pid, MRef}.
wait_task({Pid, MRef}) ->
    receive
        {ok, Pid, Return} ->
            erlang:demonitor(MRef, [flush]),
            {ok, Return};
        {'DOWN', MRef, _, _, Reason} ->
            {error, Reason}
    end.

add_opts_list(Opts) ->
    Key = {flame_opts_list, erlang:self()},
    case ets:lookup(?FLAME_DATA_ETS, Key) of
        [{_, [_|_]=L}] ->
            ets:insert(?FLAME_DATA_ETS, {Key, [Opts|L]});
        _ ->
            ets:insert(?FLAME_DATA_ETS, {Key, [Opts]})
    end.
get_all_list() ->
    lists:concat(ets:select(?FLAME_DATA_ETS, [{{'_', '$1'}, [], ['$1']}])).
new_index() ->
    Index = case erlang:get(msg_index) of undefined -> 1; V -> V+1 end,
    erlang:put(msg_index, Index),
    Index.
