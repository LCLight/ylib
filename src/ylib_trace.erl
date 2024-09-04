%%% ---------------------------
%% @doc 运行时监控工具
%%% ---------------------------
-module(ylib_trace).

-include_lib("stdlib/include/ms_transform.hrl").

-export([
    %% 简单抓取函数调用和返回信息
    %% wr(Module, Func)
    %% 如：ylib_trace:wr(erlang, send).
    %% 输出 erlang:send(self(), msg). 的调用和返回
    wr/2, wr/3, wr/4, wr/5,
    %% 根据结果过滤出合适的内容输出
    %% wrf(Module, Func, Function)
    %% 如：ylib_trace:wrf(erlang, send, fun(Ret)-> lists:member(Ret, [a,b,c]) end).
    %%  则输出 self() ! a|b|c 的调用和返回，其它消息不输出
    wrf/3, wrf/4, wrf/5,
    %% 过滤出合适的内容输出，
    %% wrf(erlang, send, fun({call, Args} | {return Ret} | {exception, Exception}|{other,Msg}) -> true | false end)
    %% 如：ylib_trace:wf(erlang, send, fun({call, [_, M]}) -> M=:=d; ({return, Ret}) -> Ret =:=a ; (A) -> false end).
    %% 仅输出 erlang:send(self(), d) 的调用和 erlang:send(self(), a) 的返回
    wf/3, wf/4, wf/5,
    %% 在其它已链接节点上创建trace，结果会在本地输出
    %% wn(Node|[Node], M, F)
    %% 例子：ylib_trace:wn('n1@127.0.0.1', erlang, send).
    %% 相当于在目标节点执行wr(erlang, send)，但可以在本节点查看输出
    wn/3, wn/4, wn/6,
    %% 在所有已链接节点上创建trace，结果会在本地输出
    %% 例子：ylib_trace:wna(erlang, send).
    %% 相当于在所有连接节点执行wr(erlang, send)，但可以在本节点查看输出，全局抓调用时经常用
    wna/2, wna/3, wna/5,
    %% 停止所有trace
    ua/0, ua/1
]).

%% [PidA] PidB ! Message   表示PidA把消息Message，投递到PidB
%% [PidB] << Message From=PidA   表示PidB收到Message消息，消息来自PidA
%% 返回的格式如上，一个消息会产生两条相似记录，所以会发现消息稍有冗余
-export([
    %% 在本节点跟踪消息
    %% msg(Mod, Func)
    %% 如：ylib_trace:msg(gen_server, call)
    %% 则跟踪调用Mod:Func发送的消息，当消息发送到其它节点时不会输出
    msg/2, msg/3,
    %% 在已经链接的所有节点跟踪消息
    %% msga(Mod, Func)
    %% 如： ylib_trace:msga(custom, send)
    %% 则跟踪调用Mod:Func发送的消息，如果消息发送到已经链接的节点，也会输出
    msga/2, msga/3
]).

-export([
    %% trace底层接口
    trace_opt/6,
    trace_opt/1,
    %% 消息跟踪底层接口
    message_opt/1,
    %% 格式化输出
    format_trace/1,
    %% 过滤匹配
    match_spec/0,
    match_spec/1,
    %% 工具函数
    filter_print/3,
    normal_print/2,
    tracer_loop/6
]).

-define(IFT(__C, __Run), case __C of true -> __Run; _ -> ok end).
-define(IF(__C, __A, __B), case __C of true -> __A; _ -> __B end).

-define(TRACE_PROC_NAME, tool_trace_trace).
-define(PRINT_PROC_NAME, tool_trace_print).
-define(MSG_PRINT(__Format, __Args), (catch io:format("~ts:~w " ++ __Format, [?MODULE, ?LINE|__Args])) ).
-define(MSG_PRINT(__Io, __Format, __Args), (catch io:format(__Io, "~ts:~w " ++ __Format, [?MODULE, ?LINE|__Args])) ).

-define(TIPS_PRINT(__Format, __Args, __Opts), case __Opts of #{quite := false} -> ?MSG_PRINT(__Format, __Args); _ -> ok end).
-define(DEBUG_PRINT(__Format, __Args, __Opts), case __Opts of #{quite := false, debug := true} -> ?MSG_PRINT(__Format, __Args); _ -> ok end).

-define(TRACE_PRINT(__Format, __Args), (catch io:format(__Format, __Args)) ).
-define(TRACE_PRINT(__Io, __Format, __Args), (catch io:format(__Io, __Format, __Args)) ).

-define(GET_MSG_OPCODE(__TraceInfo), begin erlang:is_tuple(__TraceInfo) andalso erlang:tuple_size(__TraceInfo)>=3 andalso erlang:element(3, __TraceInfo) end ).

-define(DEFAULT_OPTS,
    begin
        {_, __GLPid} = process_info(erlang:self(), group_leader),
        #{
            pid => all, %% 监控的进程Pid
            mod => '_', %% 监控的模块
            func => '_', %% 监控的函数
            arity => '_', %% 监控的函数参数
            match => match_spec(), %% 匹配规则
            auto_load => true, %% 是否自动加载监控的模块
            handle_func => {fun ?MODULE:normal_print/2, [__GLPid]}, %% 处理监控消息，默认是直接输出
            filter_func => undefined, %% 过滤输出函数
            max_frequency => 10000, %% 每秒最多多少个协议，超过自动停止
            max_lines => 200000, %% 累计最多收到多少个协议则停止，包含过滤的
            link_pid => erlang:self(), %% 链接进程，该进程挂了则退出trace
            quite => false, %% 不输出额外信息
            debug => false, %% 是否输出调试信息
            trace_opt => [] %% FlagList = [running | exiting | running_procs | ...]
        }
    end).

%% @doc 监视函数调用以及其返回值
-spec wr(term(), term()) -> {ok, pid()} | error.
wr(M, F) when is_atom(M) ->
    wr(all, M, F, '_', match_spec() ).
%% @doc 监视函数调用以及其返回值
-spec wr(term(), term(), term()) -> {ok, pid()} | error.
wr(PID, M, F) when is_pid(PID) orelse PID=:=all orelse PID=:=new orelse PID=:=existing ->
    wr(PID, M, F, '_', match_spec() );
wr(M, F, A) when is_atom(M) ->
    wr(all, M, F, A, match_spec() ).
%% @doc 监视函数调用以及其返回值
-spec wr(term(), term(), term(), term()) -> {ok, pid()} | error.
wr(PID, M, F, A) ->
    wr(PID, M, F, A, match_spec() ).
%% @doc 监视函数调用以及其返回值
-spec wr(term(), term(), term(), term(), term()) -> {ok, pid()} | error.
wr(PID, M, F, A, MatchSpec) ->
    Opts = #{mod=>M, func=>F, arity=>A, match=>MatchSpec, pid=>PID, filter_func=>undefined},
    trace_opt(Opts).

%% @doc 监视函数调用以及其返回值，过滤掉多余的信息
-spec wf(term(), term(), term()) -> {ok, pid()} | error.
wf(M, F, FilterFunc) when erlang:is_function(FilterFunc) ->
    wf(all, M, F, '_', undefined, FilterFunc);
wf(M, F, PrintMatchSpec) ->
    wf(all, M, F, '_', PrintMatchSpec, undefined).
%% @doc 监视函数调用以及其返回值，过滤掉多余的信息
-spec wf(term(), term(), term(), term()) -> {ok, pid()} | error.
wf(M, F, PrintMatchSpec, FilterFunc) ->
    wf(all, M, F, '_', PrintMatchSpec, FilterFunc).
%% @doc 监视函数调用以及其返回值，过滤掉多余的信息
-spec wf(term(), term(), term(), term(), term()) -> {ok, pid()} | error.
wf(PID, M, F, PrintMatchSpec, FilterFunc) ->
    wf(PID, M, F, '_', PrintMatchSpec, FilterFunc).
wf(PID, M, F, A, PrintMatchSpec, FilterFunc) ->
    MatchSpec =
        case PrintMatchSpec of
            {MatchHead, MatchCondition} -> [{MatchHead, MatchCondition, [{message,{caller}},{return_trace},{exception_trace}]}];
            [{MatchHead, MatchCondition, [ok]}] -> [{MatchHead, MatchCondition, [{message,{caller}},{return_trace},{exception_trace}]}]; %% 为了方便输入，把ok和true替换为常规输出内容
            [{MatchHead, MatchCondition, [true]}] -> [{MatchHead, MatchCondition, [{message,{caller}},{return_trace},{exception_trace}]}];
            [{_MatchHead, _MatchCondition, _MatchReturn}] -> PrintMatchSpec;
            _ -> match_spec()
        end,
    trace_opt(#{pid=>PID, mod=>M, func=>F, arity=>A, match=>MatchSpec, filter_func=>FilterFunc}).

%% @doc 监视函数调用以及其返回值，过滤掉多余的信息
-spec wrf(term(), term(), term()) -> {ok, pid()} | error.
wrf(M, F, ReturnFilter) when erlang:is_function(ReturnFilter) ->
    wrf(all, M, F, '_', undefined, ReturnFilter).
%% @doc 监视函数调用以及其返回值，过滤掉多余的信息
-spec wrf(term(), term(), term(), term()) -> {ok, pid()} | error.
wrf(M, F, PrintMatchSpec, ReturnFilter) ->
    wrf(all, M, F, '_', PrintMatchSpec, ReturnFilter).
%% @doc 监视函数调用以及其返回值，过滤掉多余的信息
-spec wrf(term(), term(), term(), term(), term()) -> {ok, pid()} | error.
wrf(PID, M, F, PrintMatchSpec, ReturnFilter) ->
    wrf(PID, M, F, '_', PrintMatchSpec, ReturnFilter).
wrf(PID, M, F, A, PrintMatchSpec, ReturnFilter) ->
    GLPid = erlang:group_leader(),
    MatchSpec =
        case PrintMatchSpec of
            {MatchHead, MatchCondition} -> [{MatchHead, MatchCondition, [{message,{caller}},{return_trace},{exception_trace}]}];
            [{MatchHead, MatchCondition, [ok]}] -> [{MatchHead, MatchCondition, [{message,{caller}},{return_trace},{exception_trace}]}]; %% 为了方便输入，把ok和true替换为常规输出内容
            [{MatchHead, MatchCondition, [true]}] -> [{MatchHead, MatchCondition, [{message,{caller}},{return_trace},{exception_trace}]}];
            [{_MatchHead, _MatchCondition, _MatchReturn}] -> PrintMatchSpec;
            _ -> match_spec()
        end,
    Opts = #{mod=>M, func=>F, arity=>A, match=>MatchSpec, pid=>PID,handle_func=> {fun ?MODULE:filter_print/3, [GLPid, ReturnFilter]}},
    trace_opt(Opts).

filter_print(GLPid, ReturnFilter, TraceInfo) ->
    case ?GET_MSG_OPCODE(TraceInfo) of
        return_from ->
            LastCall = pop_call(),
            filter_print(GLPid, (catch ReturnFilter(erlang:element(5, TraceInfo))), LastCall, TraceInfo);
        exception_from ->
            LastCall = pop_call(),
            filter_print(GLPid, (catch ReturnFilter(erlang:element(5, TraceInfo))), LastCall, TraceInfo);
        call ->
            push_call(TraceInfo);
        _ ->
            ?MSG_PRINT(GLPid, "~s~n", [?MODULE:format_trace(TraceInfo)])
    end.

pop_call() ->
    case erlang:get({?MODULE,pop_call}) of
        [T|L] -> erlang:put({?MODULE,pop_call}, L), T;
        _ -> undefined
    end.
push_call(TraceInfo) ->
    case erlang:get({?MODULE,pop_call}) of
        [_|_]=L -> erlang:put({?MODULE,pop_call}, [TraceInfo|L]);
        _ -> erlang:put({?MODULE,pop_call}, [TraceInfo])
    end.

filter_print(GLPid, true, CallInfo, ReturnInfo) ->
    ?TRACE_PRINT(GLPid, "~s~n", [?MODULE:format_trace(CallInfo)]),
    ?TRACE_PRINT(GLPid, "~s~n", [?MODULE:format_trace(ReturnInfo)]);
filter_print(_GLPid, _IsPrint, _Call, _Return) ->
    ok.

normal_print(GLPid, Msg) ->
    ?TRACE_PRINT(GLPid, "~s~n", [?MODULE:format_trace(Msg)]).

%% @doc 监视其它节点上的函数调用以及其返回值
-spec wn(term(), term(), term()) -> [{ok, pid()}] | [error].
wn(Node, M, F) ->
    wn(Node, M, F, '_').
%% @doc 监视其它节点上的函数调用以及其返回值
-spec wn(term(), term(), term(), term()) -> [{ok, pid()}] | [error].
wn(Node, M, F, A) ->
    wn(Node, M, F, A, erlang:self(), fun(SendNode, Msg) -> ?TRACE_PRINT("~ts ~ts~n", [SendNode, ?MODULE:format_trace(Msg)]) end ).
wn(Node, M, F, A, LinkPid, PrintFunc) ->
    Nodes =
        case erlang:is_list(Node) of
            true -> Node;
            _ -> [Node]
        end,
    PrintPid =
        case erlang:whereis(?PRINT_PROC_NAME) of
            PPid when erlang:is_pid(PPid) ->
                PPid;
            _ ->
                PrintFun = fun PrintLoop()-> receive {SendNode, Msg} -> erlang:apply(PrintFunc, [SendNode, Msg]) end, PrintLoop() end,
                erlang:spawn(fun() -> erlang:link(LinkPid), erlang:register(?PRINT_PROC_NAME, erlang:self()), PrintFun() end)
        end,
    %% 在其它节点执行trace，把收集到的消息发送到PrintPid在本地输出
    Opts = #{mod=>M, func=>F, arity=>A, link_pid=>PrintPid, handle_func=> fun(MM) -> erlang:send(PrintPid, {node(), MM}) end },
    [ {TraceNode, rpc:call(TraceNode, ?MODULE, trace_opt, [Opts])} || TraceNode <- Nodes].

wna(M, F) ->
    wna(M, F, '_').
wna(M, F, A) ->
    wna(M, F, A, erlang:self(), fun(SendNode, Msg) -> ?TRACE_PRINT("~ts ~ts~n", [SendNode, ?MODULE:format_trace(Msg)]) end ).
wna(M, F, A, LinkPid, PrintFunc) ->
    wn([erlang:node()|erlang:nodes(connected)], M, F, A, LinkPid, PrintFunc).

ua() ->
    ua(false).
ua(IsForce) ->
    case IsForce of
        true ->
            stop_trace("unwatch");
        _ ->
            case check_stop(erlang:self(), [?PRINT_PROC_NAME, ?TRACE_PROC_NAME], []) of
                true ->
                    stop_trace("unwatch");
                _Err ->
                    {error, _Err}
            end
    end.
check_stop(_OpPid, [], Acc) ->
    Acc;
check_stop(OpPid, [PName|Others], Acc) ->
    case (catch erlang:process_info(whereis(PName), links)) of
        {links, Links} ->
            case lists:member(OpPid, Links) of
                true -> true;
                _ -> check_stop(OpPid, Others, [{PName, Links}|Acc])
            end;
        _ -> check_stop(OpPid, Others, Acc)
    end.

%% @doc
%% 监控基础函数
%% trace_opt(Opts) -> {ok, Pid} | {error, Reason}.
%% Opts =
%% #{
%%     pid => all, 监控的进程Pid
%%     mod => '_', 监控的模块
%%     func => '_', 监控的函数
%%     arity => '_', 监控的函数参数
%%     match => match_spec(), 匹配规则
%%     auto_load = true, 是否自动加载监控的模块
%%     handle_func => fun(Msg) -> io:format(erlang:group_leader(), "~s~n", [format_trace(Msg)]) end, 处理监控消息，默认是直接输出
%%     filter_func = undefined, 过滤输出函数
%%     max_frequency = 10000, 每秒最多多少个协议，超过自动停止
%%     max_lines = 200000,  累计最多收到多少个协议则停止，包含过滤的
%%     link_pid = erlang:self(), 链接进程，该进程挂了则退出trace
%%     quite = false, 不输出额外信息
%%     debug = false 是否输出调试信息
%%  },
%% @end
trace_opt(PID, M, F, Arity, MatchSpec, FilterFunc) -> %%
    Opts = #{mod=>M, func=>F, arity=>Arity, match=>MatchSpec, pid=>PID,filter_func=>FilterFunc},
    trace_opt(Opts).
-spec trace_opt(Opts :: map() ) -> {ok, TracerPid :: pid()} | {error, {TPid :: pid(), tracer_already_exists}}.
trace_opt(Opts0) ->
    Opts = maps:merge(?DEFAULT_OPTS, Opts0),
    ?DEBUG_PRINT("==>~w~n", [Opts], Opts),
    case catch setup(Opts) of
        {ok, TPid} = R ->
            #{
                auto_load := AutoLoad,
                mod := Mod,
                func := Func,
                arity := Arity,
                match := MatchSpec,
                pid := PidSpec
            } = Opts,
            case AutoLoad of true -> catch code:ensure_loaded(Mod); _ -> ok end,
            ?DEBUG_PRINT("erlang:trace_pattern(~w,~w,~w)~n", [{Mod,Func,Arity}, MatchSpec, [local]], Opts),
            case catch erlang:trace(PidSpec, true, [call,timestamp,{tracer,TPid}]) of
                Int when is_integer(Int) ->
                    ok;
                _Err ->
                    ?DEBUG_PRINT("ERROR: trace failed to start:~w.~n", [_Err], Opts),
                    kill(?TRACE_PROC_NAME)
            end,
            erlang:trace_pattern({Mod,Func,Arity}, MatchSpec, [local]),
            R;
        _Err ->
            _Err
    end.

setup(Opts) ->
    case whereis(?TRACE_PROC_NAME) of
        TPid when is_pid(TPid) ->
            {_, TGLPid} = process_info(TPid, group_leader),
            {_, GLPid} = process_info(erlang:self(), group_leader),
            case TGLPid =:= GLPid of
                true ->
                    {ok, TPid};
                _ ->
                    {error, {TPid, tracer_already_exists}}
            end;
        _->
            {ok, TPid} = start_tracer(Opts),
            {ok, TPid}
    end.

%% @doc tracer for remsh with auto-stop
%% MaxFreq  := max frequency auto stop, line-per-second
%%         MaxLines := max lines auto stop
start_tracer(Opts) ->
    #{
        link_pid := LinkPid,  %% 外部进程链接，外部进程挂了，该trace停止
        max_frequency := MaxFreq, %% 每秒最多多少个协议，超过自动停止
        max_lines := MaxLines, %% 累计最多收到多少个协议则停止，包含过滤的
        handle_func := HandleFunc,
        filter_func := FilterFunc
    } = Opts,
    ?DEBUG_PRINT("link:~w max_freq:~w max_lines:~w~n", [LinkPid, MaxFreq, MaxLines], Opts),
    ?DEBUG_PRINT("start trace by:~w~n", [Opts], Opts),
    TPid = erlang:spawn_opt(fun() -> tracer(Opts, LinkPid, MaxFreq, MaxLines, HandleFunc, FilterFunc) end, [{priority,max}]),
    ?DEBUG_PRINT("~w~n", [{TPid}], Opts),
    {ok,TPid}.
tracer(Opts, LinkPid, MaxFreq, MaxLines, HandleFunc, FilterFunc) ->
    true = erlang:register(?TRACE_PROC_NAME, self()),
    erlang:process_flag(trap_exit, true),
    link(LinkPid),
    Ret = (catch ?MODULE:tracer_loop(Opts, LinkPid, HandleFunc, FilterFunc, MaxFreq, MaxLines)),
    ?MSG_PRINT("reacer ret:~p~n", [Ret]),
    Ret.

tracer_loop(Opts, LinkPid, HandleFunc, FilterFunc, MaxFreq, MaxLines) ->
    receive
        {'EXIT', LinkPid, _}=_Err ->
            stop_trace("link pid exit");
        {'$info', P} ->
            erlang:send(P, Opts);
        Msg ->
            trace_handle(Msg, HandleFunc, FilterFunc, MaxFreq, MaxLines)
    end,
    ?MODULE:tracer_loop(Opts, LinkPid, HandleFunc, FilterFunc, MaxFreq, MaxLines).
trace_handle(Msg, HandleFunc, FilterFunc, MaxFreq, MaxLines) ->
    check_freq_and_lines(erlang:system_time(second), MaxFreq, MaxLines),
    ?IFT(run_func(FilterFunc, [get_filter_msg(Msg)], true), run_func(HandleFunc, [Msg])),
    ok.

stop_trace(Reason) ->
    catch ?MSG_PRINT("terminated:~ts~n", [Reason]), %% 必须要加catch
    case erlang:whereis(?PRINT_PROC_NAME) of
        PPid when erlang:is_pid(PPid) ->
            erlang:exit(PPid, kill);
        _ ->
            ignore
    end,
    case whereis(?TRACE_PROC_NAME) of
        TPid when is_pid(TPid) ->
            clean_pattern(),
            kill(?TRACE_PROC_NAME);
        _ ->
            ignore
    end.
kill(Name) ->
    This = self(),
    case whereis(Name) of
        undefined ->
            ok;
        This ->
            throw(exit);
        Pid ->
            erlang:unlink(Pid),
            erlang:exit(Pid, kill),
            wait_for_exit(Pid)
    end.
wait_for_exit(Pid) ->
    case erlang:is_process_alive(Pid) of
        true ->
            timer:sleep(10),
            wait_for_exit(Pid);
        false ->
            ok
    end.

format_trace({trace_ts,From,call,{Mod,Func,Args}, TimeTuple}) ->
    {{{Y,Mo,D},{H,Mi,S}}, MS} = datetime(TimeTuple),
    io_lib:format("=Call=======[~p-~p-~p ~2..0w:~2..0w:~2..0w ~3..0w]==[~99999p]==[~99999p:~99999p/~99999p] Args=~99999p",[Y,Mo,D,H,Mi,S,MS,From,Mod,Func,length(Args),Args]);
format_trace({trace_ts,From,call,{Mod,Func,Args},Ext, TimeTuple}) ->
    {{{Y,Mo,D},{H,Mi,S}}, MS} = datetime(TimeTuple),
    io_lib:format("=Call=======[~p-~p-~p ~2..0w:~2..0w:~2..0w ~3..0w]==[~99999p]==[~99999p:~99999p/~99999p] Args=~99999p  @~99999p",[Y,Mo,D,H,Mi,S,MS,From,Mod,Func,length(Args),Args,Ext]);
format_trace({trace_ts,From,return_from,{Mod,Func,Arity},ReturnValue, TimeTuple}) ->
    {{{Y,Mo,D},{H,Mi,S}}, MS} = datetime(TimeTuple),
    io_lib:format("=Return=====[~p-~p-~p ~2..0w:~2..0w:~2..0w ~3..0w]==[~99999p]==[~99999p:~99999p/~99999p] Value=~99999p",[Y,Mo,D,H,Mi,S,MS,From,Mod,Func,Arity,ReturnValue]);
format_trace({trace_ts,From,exception_from,{Mod,Func,Arity},Exception, TimeTuple}) ->
    {{{Y,Mo,D},{H,Mi,S}}, MS} = datetime(TimeTuple),
    io_lib:format("=Exception!=[~p-~p-~p ~2..0w:~2..0w:~2..0w ~3..0w]==[~99999p]==[~99999p:~99999p/~99999p] Value=~99999p",[Y,Mo,D,H,Mi,S,MS,From,Mod,Func,Arity,Exception]);
format_trace({trace,From,call,{Mod,Func,Args}}) ->
    format_trace({trace_ts,From,call,{Mod,Func,Args}, now_time()});
format_trace({trace,From,call,{Mod,Func,Args},Ext}) ->
    format_trace({trace_ts,From,call,{Mod,Func,Args},Ext, now_time()});
format_trace({trace,From,return_from,{Mod,Func,Arity},ReturnValue}) ->
    format_trace({trace_ts,From,return_from,{Mod,Func,Arity},ReturnValue, now_time()});
format_trace({trace,From,exception_from,{Mod,Func,Arity},Exception}) ->
    format_trace({trace_ts,From,exception_from,{Mod,Func,Arity},Exception, now_time()});

format_trace({seq_trace, Label, SeqTraceInfo, TimeTuple}) ->
    seq_format_trace(datetime(TimeTuple), Label, SeqTraceInfo);
format_trace({seq_trace, Label, SeqTraceInfo}) ->
    seq_format_trace(now_time(), Label, SeqTraceInfo);
format_trace(M) ->
    {{{Y,Mo,D},{H,Mi,S}}, MS} = {erlang:localtime(), erlang:system_time(millisecond) rem 1000},
    io_lib:format("===unknown!=[~p-~p-~p ~2..0w:~2..0w:~2..0w ~3..0w]==~99999p",[Y,Mo,D,H,Mi,S,MS,M]).

seq_format_trace({{{Y,Mo,D},{H,Mi,S}}, MS}, Label, {send, Serial, From, To, Message}) ->
    io_lib:format("===Send=======[~p-~p-~p ~2..0w:~2..0w:~2..0w ~3..0w]==[~99999p]==[~99999p] ~99999p ! ~99999p Serial=~99999p",[Y,Mo,D,H,Mi,S,MS,Label,From,To,Message,Serial]);
seq_format_trace({{{Y,Mo,D},{H,Mi,S}}, MS}, Label, {'receive', Serial, From, To, Message}) ->
    io_lib:format("===Recv=======[~p-~p-~p ~2..0w:~2..0w:~2..0w ~3..0w]==[~99999p]==[~99999p] << ~99999p  From=~99999p, Serial=~99999p",[Y,Mo,D,H,Mi,S,MS,Label,To,Message,From,Serial]);
seq_format_trace({{{Y,Mo,D},{H,Mi,S}}, MS}, Label, {print, Serial, From, _, Message}) ->
    io_lib:format("===Print=======[~p-~p-~p ~2..0w:~2..0w:~2..0w ~3..0w]==[~99999p]==[~99999p] ~99999p Serial=~99999p",[Y,Mo,D,H,Mi,S,MS,Label,From,Message,Serial]).


match_spec() ->
    match_spec(caller_return).
match_spec(caller_return) ->
    dbg:fun2ms(fun(_) -> message(caller()), return_trace(), exception_trace() end);
match_spec(caller) ->
    dbg:fun2ms(fun(_) -> message(caller()) end);
match_spec(return) ->
    dbg:fun2ms(fun(_) -> message(false), return_trace(), exception_trace() end);
match_spec(_Default) ->
    dbg:fun2ms(fun(_) -> message(caller()), return_trace(), exception_trace() end).

clean_pattern() ->
    erlang:trace(all, false, [all]),
    erlang:trace_pattern({'_','_','_'}, false, [local,meta,call_count,call_time]),
    erlang:trace_pattern({'_','_','_'}, false, []),
    seq_trace:set_system_tracer(false),
    ok.

check_freq_and_lines(Now, MaxFreq, MaxLines) ->
    case erlang:get(last_line) of
        {Now, C1} when C1>MaxFreq -> stop_trace("max frequency");
        {Now, C1} -> ok;
        _ ->  C1 = 0
    end,
    erlang:put(last_line, {Now,C1+1}),
    case erlang:get(line_count) of
        undefined -> C2 = 0;
        C2 when C2>MaxLines -> stop_trace("max lines");
        C2 -> ok
    end,
    erlang:put(line_count, C2+1),
    ok.
get_filter_msg(Info) ->
    case ?GET_MSG_OPCODE(Info) of
        call ->
            {_,_,Args} = erlang:element(4, Info), {call, Args};
        return_from ->
            Ret = erlang:element(5, Info), {return, Ret};
        exception_from ->
            Exception = erlang:element(5, Info), {exception, Exception};
        _ ->
            {other, Info}
    end.

now_time() ->
    Millisecond = erlang:system_time(millisecond),
    Datetime = calendar:system_time_to_local_time(Millisecond, millisecond),
    {Datetime, Millisecond rem 1000}.

datetime({MegaSecs, Secs, MicroSecs}) when erlang:is_integer(MegaSecs) ->
    {calendar:system_time_to_local_time(MegaSecs*1000000+Secs, second), MicroSecs div 1000};
datetime({{_,_}, _MS} = T) ->
    T.

msg(Mod, Func) when erlang:is_atom(Mod) andalso erlang:is_atom(Func) ->
    msg(all, {Mod, Func, '_'}, undefined).

msg(Mod, Func, Arity) when erlang:is_integer(Arity) andalso erlang:is_atom(Mod) andalso erlang:is_atom(Func) ->
    msg(all, {Mod, Func, Arity}, undefined);
msg(Pid, Mod, Func) when erlang:is_atom(Mod) andalso erlang:is_atom(Func) ->
    msg(Pid, {Mod, Func, '_'}, undefined);
msg(Pid, {Mod, Func, Arity}, Pattern) ->
    MatchSpec = fix_pattern(Pattern, [{set_seq_token, send, true}, {set_seq_token,'receive',true}]),
    Opts = #{mod=>Mod, func=>Func, arity=>Arity, match=>MatchSpec, pid=>Pid},
    message_opt(Opts).


msga(Mod, Func) when erlang:is_atom(Mod) andalso erlang:is_atom(Func) ->
    msga(all, {Mod, Func, '_'}, undefined).

msga(Mod, Func, Arity) when erlang:is_integer(Arity) andalso erlang:is_atom(Mod) andalso erlang:is_atom(Func) ->
    msga(all, {Mod, Func, Arity}, undefined);
msga(Pid, Mod, Func) when erlang:is_atom(Mod) andalso erlang:is_atom(Func) ->
    msga(Pid, {Mod, Func, '_'}, undefined);
msga(Pid, {Mod, Func, Arity}, Pattern) ->
    MatchSpec = fix_pattern(Pattern, [{set_seq_token, send, true}, {set_seq_token,'receive',true}]),
    LinkPid = erlang:self(),
    PrintPid =
        case erlang:whereis(?PRINT_PROC_NAME) of
            PPid when erlang:is_pid(PPid) ->
                PPid;
            _ ->
                PrintFun = fun PrintLoop()-> receive {SendNode, Msg} -> ?TRACE_PRINT("~ts ~ts~n", [SendNode, ?MODULE:format_trace(Msg)]) end, PrintLoop() end,
                erlang:spawn(fun() -> erlang:link(LinkPid), erlang:register(?PRINT_PROC_NAME, erlang:self()), PrintFun() end)
        end,
    %% 在其它节点执行trace，把收集到的消息发送到PrintPid在本地输出
    Opts = #{mod=>Mod, func=>Func, arity=>Arity, match=>MatchSpec, pid=>Pid, link_pid=>PrintPid, handle_func=> fun(MM) -> erlang:send(PrintPid, {node(), MM}) end },
    message_opt(Opts),
    Opts2 = Opts#{pid=>undefined},
    [rpc:call(N, ?MODULE, message_opt, [Opts2])|| N <- erlang:nodes(connected)].

message_opt(Opts0) ->
    Opts = maps:merge(?DEFAULT_OPTS, Opts0),
    ?DEBUG_PRINT("==>~w~n", [Opts],Opts),
    case catch setup(Opts) of
        {ok, TPid} = R ->
            #{
                auto_load := AutoLoad,
                mod := Mod,
                func := Func,
                arity := Arity,
                match := MatchSpec,
                pid := PidSpec
            } = Opts,
            ?IFT(AutoLoad, catch code:ensure_loaded(Mod) ),
            ?DEBUG_PRINT("erlang:trace_pattern(~w,~w,~w)~n", [{Mod,Func,Arity}, MatchSpec, [local]], Opts),
            seq_trace:set_system_tracer(TPid),
            case PidSpec=/=undefined of
                true ->
                    dbg:tracer(),
                    dbg:tpl({Mod, Func, Arity}, MatchSpec),
                    dbg:p(PidSpec, [call]), %% FLAG timestamp not work
                    ok;
                _ ->
                    ignore
            end,
            R;
        _Err ->
            _Err
    end.

%% 把满足格式的trace pattern替换返回值，其它情况返回默认值
%% 为了方便输入，把ok和true替换为常规输出内容
fix_pattern('_', FixReturn) ->
    [{'_', [], FixReturn}];
fix_pattern(undefined, FixReturn) ->
    [{'_', [], FixReturn}];
fix_pattern({A, B}, FixReturn) ->
    {A, B, FixReturn};
fix_pattern(Pattern, FixReturn) when erlang:is_list(Pattern) ->
    [begin
         case P of
             {A, B, [ok]} -> {A, B, FixReturn};
             {A, B, [true]} -> {A, B, FixReturn};
             _ -> P
         end
     end || P <- Pattern].

run_func(undefined, _Args, Default) ->
    Default;
run_func(Function, Args, _Default) ->
    run_func(Function, Args).

run_func(Function, Args) when erlang:is_function(Function) ->
    erlang:apply(Function, Args);
run_func({F, A}, Args) ->
    erlang:apply(F, A++Args);
run_func({M,F,A}, Args) ->
    erlang:apply(M,F,A++Args).
