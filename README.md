# ylib
erlang工具

ylib_flame
----
生成火焰图工具，注意性能影响，生产环境慎用
可以对单个函数的执行，或者运行中的进程进行分析，


> 函数分析 ylib_flame:apply({M, F, A}).  
> 
> ylib_flame:apply({io, format, ["~3p", [123456]]})  
>

> %% 进程分析 ylib_flame:start([RuningPid]).  
> 
> ylib_flame:start([code_server]).  
> code:add_path(".").  
> ylib_flame:stop().
>

执行成功后，会提示：  
writing:Your/Path/stacks_XXX.out, Count  
run script to dump svg  
./stack_to_flame.sh  Your/Path/stacks_XXX.out  
安装了perl直接执行即可

demo

    %% demo.erl
    t() ->
        trace函数
        ylib_flame:apply({?MODULE, run_once, []}),
        %% trace运行中进程
        {ok, Server} = demo:start_link(),
        Pid = erlang:spawn(?MODULE, run_loop, [Server]),
        ylib_flame:start([Pid,Server]),
        timer:sleep(500),
        ylib_flame:stop(),
        Pid ! stop,
        ok.

> demo:t()
> 
![demo](flame_stacks_2023_09_04_15_09_03.1.svg)
![demo](flame_stacks_2023_09_04_15_09_03.svg)

其它

灰色部分为调用gen_server:call的等待时间

ylib_opts
----
用于解析选项参数

    %% demo.es  
    main(Args) ->  
        io:format("~p~n", [ylib_opts:parse_opts(Args, #{auto_opt=>true})]),  
        ok.
调用时  

    escript demo.es "./www","/tmp","--url", "192.168.0.5","8080","192.168.0.6","8081","-u","admin" ,"--passwd","abcd"   

    $> #{"--default" => ["./www","/tmp"],
    "--passwd" => ["abcd"],
    "--url" => ["192.168.0.5","8080","192.168.0.6","8081"],
    "-u" => ["admin"]}

直接使用

    1> ylib_opts:parse_opts(["./www","/tmp","--url", "192.168.0.5","8080","192.168.0.6","8081","-u","admin" ,"--passwd","abcd"],
    [{"--url", [{str,int}]}, {"-u", str}, {"--passwd", str}]).

    #{"--default" => ["./www","/tmp"],
    "--passwd" => "abcd",
    "--url" => [{"192.168.0.5",8080},{"192.168.0.6",8081}],
    "-u" => "admin"}

如果加上 atom_key => true，则所有key会去掉"-"或者"--"并转为atom。  

    #{default => ["./www","/tmp"],
    passwd => "abcd",u => "admin",
    url => [{"192.168.0.5",8080},{"192.168.0.6",8081}]}



ylib_trace
----
用于跟踪函数调用，消息顺序等

    使用例子
    ylib_trace:wr(erlang, send).
    ylib_trace:wrf(erlang, send, fun(Ret)-> lists:member(Ret, [a,b,c]) end).
    ylib_trace:wf(erlang, send, fun({call, [_, M]}) -> M=:=d; ({return, Ret}) -> Ret =:=a ; (A) -> false end).
    ylib_trace:wn('n1@127.0.0.1', erlang, send).
    ylib_trace:wna(erlang, send).

    跟踪消息
    werl -name n1@127.0.0.1
    werl -name n2@127.0.0.1
    werl -name n3@127.0.0.1
    再在n3执行
    lists:foldl(fun(Node, Pid) ->
        erlang:spawn(Node, fun()->
                erlang:register(a, self()),
                fun RF(P) ->
                    receive Msg ->
                        io:format("~ts => ~w => ~p~n", [node(), Msg, P]),
                        case erlang:is_pid(P) of true -> erlang:send(P, Msg);_ -> ok end
                    end,
                    RF(P)
                end(Pid) end)
        end, undefined, ['n1@127.0.0.1', 'n2@127.0.0.1', 'n3@127.0.0.1']).
    
    ylib_trace:msga(self(), erlang, send).
    erlang:send(a, msg).




ylib_time
----
用于处理时间相关内容

    使用例子
    1> ylib_time:now().
    1727772606

    2> ylib_time:date(ylib_time:now()).
    {2024,10,1}

    3> ylib_time:datetime(ylib_time:now()).
    {{2024,10,1},{16,50,52}}

    4> ylib_time:day_of_week(ylib_time:now()).
    2

