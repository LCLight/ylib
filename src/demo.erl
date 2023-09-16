-module(demo).

-behaviour(gen_server).

-export([
    t/0,
    run_once/0,
    run_loop/1
]).
-export([
    start_link/0,
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

%% gen_server
start_link() -> gen_server:start_link(?MODULE, [], []).
init(_) -> {ok, []}.
handle_call({calc, X}, _From, State) -> {reply, get_res(X), State}.
handle_cast(_Msg, State) -> {noreply, State}.
handle_info(_Info, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.
code_change(_, State, _) -> {ok, State}.
get_res(X) when X>0 -> (X+1)/2 + get_res(X-1);
get_res(_X) -> 0.

%% ==========
t() ->
    %% trace函数
    ylib_flame:apply({?MODULE, run_once, []}),
        
    %% trace运行中进程
    {ok, Server} = demo:start_link(),
    Pid = erlang:spawn(?MODULE, run_loop, [Server]),
    ylib_flame:start([Pid,Server]),
    timer:sleep(500),
    ylib_flame:stop(),
    Pid ! stop,
        
    ok.

run_once() ->
    List = lists:seq(1, 100),
    {ok, Server} = demo:start_link(),
    gen_server:call(Server, {calc, 100}),
    _ = run3(List, []),
    ok.

run_loop(Server) ->
    List2 = lists:seq(1, 100),
    List3 = run2(List2),
    gen_server:call(Server, {calc, 100}),
    _List4 = run3(List3, []),
    receive
        _ ->
            ok
    after 100 ->
        run_loop(Server)
    end.

run2([T|List]) ->
    [ T*2+1| run2(List)];
run2([]) ->
    [].
run3([T|List], Acc) ->
    run3(List, [T / 2 |Acc]);
run3([], Acc) ->
    Acc.



