%%% --------------------------------------
%% @doc 常用时间接口封装
%% @end
%%% --------------------------------------
-module(ylib_time).

%% 获取时间
-export([ now/0, now_sec/0, now_msec/0, now_usec/0]).

%% 格式转换
-export([ localtime/0, datetime/0, datetime/1, date/0, date/1, time/0, time/1,
    timestamp/1, zero_timestamp/0, zero_timestamp/1,
    day_of_week/0, day_of_week/1, last_day_of_month/1, last_day_of_month/2,
    week_beginning/1, month_beginning/1, month_ending/1,
    datetime_str/0, datetime_str/1, time_str/0, time_str/1
     ]).

%% 日期计算
-export([ get_time_offset/0, is_same_week/1, is_same_week/2,
    add_days/2, diff_next_daytime/1, diff_next_daytime/2,
    diff_days/2, diff_days_abs/2, diff_seconds/2,
    is_same_date/1, is_same_date/2,
    get_age/1, get_time_age/2 ]).
-export([
    simple_test/0
]).
-type year() :: 1970..10000.
-type month() :: 1..12.
-type day() :: 1..31.
-type hour() :: 0..23.
-type minute() :: 0..59.
-type second() :: 0..59.
-type week() :: 1..7.
-type date() :: {year(), month(), day()}.
-type time() :: {hour(), minute(), second()}.
-type datetime() :: {date(), time()}.
-type timestamp() :: integer().

-type any_date() :: timestamp() | datetime() | date().
-type any_time() :: timestamp() | datetime() | time().

%% 本地时间
-define(BASE_TIME_1970_1_1, {{1970, 1, 1}, {0, 0, 0}}).
-define(GREGORIAN_SECONDS_FROM_0_TO_1970_LOCAL,
    (case persistent_term:get({?MODULE, universal_timestamp}, undefined) of
         undefined ->
             V = calendar:datetime_to_gregorian_seconds(calendar:universal_time_to_local_time(?BASE_TIME_1970_1_1)),
             persistent_term:put({?MODULE, universal_timestamp}, V),
             V;
         V when erlang:is_integer(V) -> V
     end)
).
%% 一周以哪一天开始： 1..7分别代表 星期一 到 星期日，如有变更自行修改
-define(BEGINNING_DAY_OF_WEEK, 1).
-define(ONE_WEEK_SECONDS, 604800).
-define(ONE_DAY_SECONDS, 86400).
-define(ONE_HOUR_SECONDS, 3600).
-define(ONE_MINUTE_SECONDS, 60).

%%%% 基本获取时间接口，本模块其它获取时间行为，均使用这几个接口
-spec now() -> timestamp().
%% @doc 秒时间戳
now() -> now_sec().

-spec now_sec() -> timestamp().
%% @doc 秒时间戳
now_sec() -> erlang:system_time(second).

-spec now_msec() -> timestamp().
%% @doc 毫秒时间戳
now_msec() -> erlang:system_time(millisecond).

-spec now_usec() -> timestamp().
%% @doc 微秒时间戳
now_usec() -> erlang:system_time(microsecond).

-spec localtime() -> datetime().
localtime() -> datetime().

-spec datetime() -> datetime().
datetime() -> datetime(?MODULE:now_sec()).

%% @doc 某个时间戳的时间点
-spec datetime( any_date() | any_time() ) -> datetime().
datetime({Y,_M,_D}=Date) when Y>24 -> {Date, {0,0,0}};
datetime({_H,_M,_S}=Time) -> {?MODULE:date(), Time};
datetime({{_,_,_},{_,_,_}}=Datetime) -> Datetime;
datetime(TimeStamp) -> calendar:gregorian_seconds_to_datetime(?GREGORIAN_SECONDS_FROM_0_TO_1970_LOCAL + TimeStamp).

-spec date() -> date().
%% @doc 当前日期
date() -> date(?MODULE:now_sec()).

-spec date( any_date() ) -> date().
%% @doc 某个时间戳的日期
date({_Y,_M,_D}=Date) -> Date;
date({{_,_,_}=Date,{_,_,_}}) -> Date;
date(TimeStamp) ->
    {Date, _} = datetime(TimeStamp),
    Date.

-spec time() -> time().
%% @doc 当前时分秒
time() ->
    {_, Time} = datetime(),
    Time.
-spec time( any_time() ) -> time().
%% @doc 某个时间戳的时分秒
time({_H,_M,_S}=Time) -> Time;
time({{_,_,_},{_,_,_}=Time}) -> Time;
time(TimeS) ->
    {_, Time} = datetime(TimeS),
    Time.

-spec timestamp( any_date() ) -> timestamp().
%% @doc 某个时间点的时间戳
timestamp({YY, MM, DD}) when YY >= 1970 -> timestamp({{YY, MM, DD}, {0, 0, 0}});
timestamp({{Y, M, D}, {HH, MM, SS}}) -> calendar:datetime_to_gregorian_seconds({{Y, M, D}, {HH, MM, SS}}) - ?GREGORIAN_SECONDS_FROM_0_TO_1970_LOCAL;
timestamp(TimeStamp) when erlang:is_integer(TimeStamp) -> TimeStamp.


-spec zero_timestamp() -> timestamp().
%% @doc 今天凌晨0点时间戳
zero_timestamp() -> zero_timestamp(?MODULE:now_sec()).

-spec zero_timestamp( any_date() ) -> timestamp().
%% @doc 计算时间戳TimeStamp当天的0点时间戳
zero_timestamp({_Y,_M,_D}=Date) -> timestamp({Date, {0,0,0}});
zero_timestamp({{_,_,_}=Date,{_,_,_}}) -> timestamp({Date, {0,0,0}});
zero_timestamp(TimeStamp) -> TimeStamp - (TimeStamp + ?GREGORIAN_SECONDS_FROM_0_TO_1970_LOCAL) rem ?ONE_DAY_SECONDS.


-spec day_of_week() -> week().
%% @doc 当前是星期几
day_of_week() -> day_of_week(?MODULE:date()).

-spec day_of_week( any_date() ) -> week().
%% @doc 日期是星期几
day_of_week({{_,_,_}=Date, {_,_,_}}) -> day_of_week(Date);
day_of_week({_, _, _} = Date) -> calendar:day_of_the_week(Date);
day_of_week(Time) -> day_of_week(date(Time)).

-spec last_day_of_month( any_date() ) -> day().
%% @doc 返回该月的最后一天
last_day_of_month({{Year,Month,_}, {_Hohr, _Min, _Sec}}) ->
    last_day_of_month(Year, Month);
last_day_of_month({Year,Month,_}) ->
    last_day_of_month(Year, Month);
last_day_of_month(TimeStamp) ->
    {Year, Month, _} = ?MODULE:date(TimeStamp),
    last_day_of_month(Year, Month).
last_day_of_month(Year, Month) ->
    calendar:last_day_of_the_month(Year, Month).


-spec week_beginning( any_date() ) -> timestamp().
%% @doc 计算一周的开始时间戳
week_beginning(T) ->
    %% 当天的起始时间，减去距离一周起始过了多少天
    Midnight = zero_timestamp(T),
    Dow = day_of_week(T) - ?BEGINNING_DAY_OF_WEEK,
    DiffDay =
        case (Dow >= 0) of
            true -> Dow;
            _ -> 7 + Dow
        end,
    Midnight - DiffDay * ?ONE_DAY_SECONDS.

-spec month_beginning( any_date() ) -> timestamp().
%% @doc 计算一月的开始时间戳(每月1号的凌晨开始)
month_beginning(TimeStamp) ->
    {Y,M,_D} = date(TimeStamp),
    timestamp({{Y,M,1}, {0,0,0}}).

-spec month_ending( any_date() ) -> timestamp().
%% @doc 本月结束时间戳，也就是下一月的开始时间戳
month_ending(T) ->
    {Y, M, _} = ?MODULE:date(T),
    D = ?MODULE:last_day_of_month(Y, M),
    ?MODULE:timestamp({{Y, M, D}, {0, 0, 0}}) + ?ONE_DAY_SECONDS.

-spec datetime_str() -> string().
%% @doc 当前日期时间，格式如"2015-11-23 17:50:48"
datetime_str() -> datetime_str(?MODULE:localtime()).

-spec datetime_str( timestamp() | datetime() ) -> string().
%% @doc 时间戳转换为日期时间格式，结果格式:"2015-11-23 17:50:48"
datetime_str({{Y, M, D}, {HH, MM, SS}}) ->
    lists:flatten(io_lib:format("~w-~2..0B-~2..0B ~2..0B:~2..0B:~2..0B", [Y, M, D, HH, MM, SS]));
datetime_str(Timestamp) ->
    datetime_str(datetime(Timestamp)).

-spec time_str() -> string().
%% @doc 获取当前时间的时分秒格式:"HH:MM:SS"
time_str() -> time_str(?MODULE:time()).

-spec time_str( any_time() ) -> string().
time_str({HH, MM, SS}) -> lists:flatten(io_lib:format("~2..0B:~2..0B:~2..0B", [HH, MM, SS]));
time_str(T) -> time_str(?MODULE:time(T)).

-spec get_time_offset() -> TimeOffset :: integer().
get_time_offset() ->
    ?GREGORIAN_SECONDS_FROM_0_TO_1970_LOCAL - calendar:datetime_to_gregorian_seconds(?BASE_TIME_1970_1_1).

-spec is_same_week( any_date() ) -> true | false.
%% @doc 日期和今天是否同周
is_same_week(T) -> is_same_week(date(T), ?MODULE:date()).

-spec is_same_week( any_date(), any_date()) -> true | false.
%% @doc 两个日期是否同一周
is_same_week({_, _, _} = Date1, {_, _, _} = Date2) -> calendar:iso_week_number(Date1) =:= calendar:iso_week_number(Date2);
is_same_week(T1, T2) -> is_same_week(date(T1), date(T2)).

-spec add_days( any_date(), Days :: integer() ) -> any_date().
%% @doc 日期增加天数，原样返回
add_days({{_,_,_}=Date, Time}, Days) -> {calendar:gregorian_days_to_date( calendar:date_to_gregorian_days(Date) + Days ), Time};
add_days({_,_,_}=Date, Days) -> calendar:gregorian_days_to_date( calendar:date_to_gregorian_days(Date) + Days );
add_days(Timestamp, Days) -> Timestamp + Days * ?ONE_DAY_SECONDS.

-spec diff_next_daytime( time() ) -> integer().
%% @doc 距离下一次的时间还有多久
diff_next_daytime(NextTime) ->
    diff_next_daytime(?MODULE:time(), NextTime).

-spec diff_next_daytime( any_time(), Daytime :: time() ) -> integer().
diff_next_daytime({CurH, CurM, CurS}, {Hour, Min, Sec}) ->
    Diff = (Hour-CurH) * ?ONE_HOUR_SECONDS + (Min-CurM) * ?ONE_MINUTE_SECONDS + (Sec-CurS),
    case Diff=<0 of
        true -> Diff + ?ONE_DAY_SECONDS;
        _ -> Diff
    end;
diff_next_daytime(Time, NextTime) when erlang:is_integer(Time) ->
    diff_next_daytime(time(Time), NextTime).

-spec diff_days( any_date(), any_date()) -> integer().
%% @doc 计算两个时间相差的天数，前面的日期大时返回正数
diff_days({_,_,_}=Date1, {_,_,_}=Date2) ->
    calendar:date_to_gregorian_days(Date1) - calendar:date_to_gregorian_days(Date2);
diff_days(T1, T2) ->
    diff_days(?MODULE:date(T1), ?MODULE:date(T2)).

-spec diff_days_abs( any_date(), any_date()) -> integer().
%% @doc 计算两个时间戳或者两个日期相隔的天数
diff_days_abs(Date1, Date2) -> erlang:abs(diff_days(Date1, Date2)).

-spec diff_seconds( any_date(), any_date()) -> integer();
    ( time(), time()) -> integer().
%% @doc 两个时间相隔的秒数，前者大时为正数
diff_seconds({Hour1, Min1, Sec1}, {Hour2, Min2, Sec2}) when Hour1=<24 andalso Hour2=<24 ->
    (Hour1-Hour2) * ?ONE_HOUR_SECONDS + (Min1-Min2) * ?ONE_MINUTE_SECONDS + Sec1-Sec2;
diff_seconds(Time1, Time2) when erlang:is_integer(Time1) andalso erlang:is_integer(Time2) ->
    Time1 - Time2;
diff_seconds(T1, T2) ->
    timestamp(T1) - timestamp(T2).

-spec is_same_date( any_date() ) -> boolean().
%% @doc 跟当前时间是不是同一天
is_same_date( T ) -> is_same_date(?MODULE:date(T), ?MODULE:date()).

-spec is_same_date( any_date(), any_date() ) -> boolean().
%% @doc 两个时间是否是同一天
is_same_date({_,_,_}=T1, {_,_,_}=T2) -> T1 =:= T2;
is_same_date(T1, T2) -> ?MODULE:date(T1) =:= ?MODULE:date(T2).

-spec get_age( any_date() ) -> integer().
%% 返回年龄，以天计算，出生一年内算0岁
get_age(AgeTime) -> get_time_age(?MODULE:date(AgeTime), ?MODULE:date()).

-spec get_time_age( any_date(), any_date() ) -> integer().
get_time_age({_,_,_}=AgeDate, {_,_,_}=NowDate) when NowDate =< AgeDate -> 0;
get_time_age({AgeYear, AgeMonth, AgeDay}, {NowYear, NowMonth, NowDay}) when {NowMonth, NowDay} < {AgeMonth, AgeDay} ->
    %% 生日还没到
    NowYear - AgeYear - 1;
get_time_age({AgeYear, _AgeMonth, _AgeDay}, {NowYear, _NowMonth, _NowDay}) ->
    NowYear - AgeYear;
get_time_age(T1, T2) -> get_time_age(?MODULE:date(T1), ?MODULE:date(T2)).

-define(IF(__T, __A, __B), case __T of true -> __A; _ -> __B end).
-define(PASS, ok).
simple_test() ->
    SecDay = 60*60*24,
    SecNYear = 60*60*24*365,
    BaseTime = 1656604800, %% {{2022,7,1},{0,0,0}}
    BaseDate = ?MODULE:datetime(BaseTime),
    Midnight0701 = 1656604800,
    BeginMonth0701 = 1656604800,
    NextMonth_0801 = 1659283200,
    BeginWeek1_0627 = 1656259200,
    DiffDateBases = [{{2022,7,1},{0,0,0}}, {{2022,7,1},{4,0,0}}, {{2022,7,1},{23,59,59}}, {{2022,7,1},{12,0,0}}],
    DiffDate0701 = 0,
    TimeArray = #{
        BaseTime - SecDay*4 => #{dt => {{2022,6,27},{0,0,0}}, w => 1, bw => BeginWeek1_0627, mn => Midnight0701-SecDay*4, dd1 => DiffDate0701-4 },
        BaseTime => #{dt => {{2022,7,1},{0,0,0}}, w => 5, bm => BeginMonth0701, nm => NextMonth_0801, bw => BeginWeek1_0627, mn => Midnight0701, dd1 => DiffDate0701 },
        BaseTime + 1 => #{dt => {{2022,7,1},{0,0,1}}, w => 5, bm => BeginMonth0701, nm => NextMonth_0801, bw => BeginWeek1_0627, mn => Midnight0701, dd1 => DiffDate0701 },
        BaseTime + 60 => #{dt => {{2022,7,1},{0,1,0}}, w => 5, bm => BeginMonth0701, nm => NextMonth_0801, bw => BeginWeek1_0627, mn => Midnight0701, dd1 => DiffDate0701 },
        BaseTime + 60*5 => #{dt => {{2022,7,1},{0,5,0}}, w => 5, bm => BeginMonth0701, nm => NextMonth_0801, bw => BeginWeek1_0627, mn => Midnight0701, dd1 => DiffDate0701 },
        BaseTime + 60*59 => #{dt => {{2022,7,1},{0,59,0}}, w => 5, bm => BeginMonth0701, nm => NextMonth_0801, bw => BeginWeek1_0627, mn => Midnight0701, dd1 => DiffDate0701 },
        BaseTime + 60*60 => #{dt => {{2022,7,1},{1,0,0}}, w => 5, bm => BeginMonth0701, nm => NextMonth_0801, bw => BeginWeek1_0627, mn => Midnight0701, dd1 => DiffDate0701 },
        BaseTime + 60*60*23 => #{dt => {{2022,7,1},{23,0,0}}, w => 5, bm => BeginMonth0701, nm => NextMonth_0801, bw => BeginWeek1_0627, mn => Midnight0701, dd1 => DiffDate0701 },
        BaseTime + SecDay-1 => #{dt => {{2022,7,1},{23,59,59}}, w => 5, bm => BeginMonth0701, nm => NextMonth_0801, bw => BeginWeek1_0627, mn => Midnight0701, dd1 => DiffDate0701 },
        BaseTime + SecDay => #{dt => {{2022,7,2},{0,0,0}}, w => 6, bm => BeginMonth0701, nm => NextMonth_0801, bw => BeginWeek1_0627, mn => Midnight0701+SecDay, dd1 => DiffDate0701+1 },
        BaseTime + SecDay*3-1 => #{dt => {{2022,7,3},{23,59,59}}, w => 7, bm => BeginMonth0701, nm => NextMonth_0801, bw => BeginWeek1_0627, dd1 => DiffDate0701+2 },
        BaseTime + SecDay*3 => #{dt => {{2022,7,4},{0,0,0}}, w => 1, bm => BeginMonth0701, nm => NextMonth_0801, bw => BeginWeek1_0627+SecDay*7, dd1 => DiffDate0701+3 },

        BaseTime + SecDay*7-1 => #{w => 4, bm => BeginMonth0701, nm => NextMonth_0801 },
        BaseTime + SecDay*7 => #{w => 5, bm => BeginMonth0701, nm => NextMonth_0801 },
        BaseTime + SecDay*7*2-1 => #{w => 4, bm => BeginMonth0701, nm => NextMonth_0801 },
        BaseTime + SecDay*7*2 => #{w => 5, bm => BeginMonth0701, nm => NextMonth_0801 },
        BaseTime + SecDay*31-1 => #{dt => {{2022,7,31},{23,59,59}}, w => 7, bm => BeginMonth0701, nm => NextMonth_0801 },
        BaseTime + SecDay*31 => #{dt => {{2022,8,1},{0,0,0}}, w => 1, bm => NextMonth_0801, nm => NextMonth_0801 + SecDay*31},
        BaseTime + SecDay*(31+31)-1 => #{dt => {{2022,8,31},{23,59,59}}, w => 3, bm => NextMonth_0801, nm => NextMonth_0801 + SecDay*31 },
        BaseTime + SecDay*(31+31) => #{dt => {{2022,9,1},{0,0,0}}, w => 4 },

        BaseTime + SecNYear-1 => #{dt => {{2023,6,30},{23,59,59}}, w => 5, dd1 => DiffDate0701+364 },
        BaseTime + SecNYear => #{dt => {{2023,7,1},{0,0,0}}, w => 6, dd1 => DiffDate0701+365 },
        %% 2024是闰年,多加一天
        BaseTime + SecNYear+SecNYear+SecDay-1 => #{dt => {{2024,6,30},{23,59,59}}, w => 7, dd1 => DiffDate0701+365+365 },
        BaseTime + SecNYear+SecNYear+SecDay => #{dt => {{2024,7,1},{0,0,0}}, w => 1, dd1 => DiffDate0701+365+366 }
    },
    maps:map(fun(SrcTime, RetMap) ->
        %% datetime/data/time
        SrcDTime = ?MODULE:time(SrcTime),
        case maps:get(dt, RetMap, ignore) of
            ignore -> ok;
            {Date, Time} = DateTime ->
                ?IF(?MODULE:datetime(SrcTime) =:= DateTime, ?PASS, erlang:throw({error, SrcTime, DateTime})),
                ?IF(?MODULE:date(SrcTime) =:= Date, ?PASS, erlang:throw({error, SrcTime, Date})),
                ?IF(?MODULE:time(SrcTime) =:= Time, ?PASS, erlang:throw({error, SrcTime, Time})),
                %% 转换回去
                ?IF( ?MODULE:timestamp(DateTime) =:= SrcTime, ?PASS, erlang:throw({error, SrcTime, Time})),
                %% 计算相差秒数
                ?IF(?MODULE:diff_seconds(DateTime, BaseDate) =:= (SrcTime-BaseTime), ok, erlang:throw({error, DateTime, BaseDate, SrcTime - BaseTime})),
                ?IF(?MODULE:diff_seconds(BaseDate, DateTime) =:= (BaseTime-SrcTime), ok, erlang:throw({error, BaseDate, DateTime, BaseTime - SrcTime}))
        end,
        %%
        case maps:get(w, RetMap, ignore) of
            ignore -> ok;
            Week -> ?IF(?MODULE:day_of_week(SrcTime) =:= Week, ?PASS, erlang:throw({error, SrcTime, Week}))
        end,
        case maps:get(bm, RetMap, ignore) of
            ignore -> ok;
            BeginMonth -> ?IF(?MODULE:month_beginning(SrcTime) =:= BeginMonth, ?PASS, erlang:throw({error, SrcTime, BeginMonth}))
        end,
        case maps:get(nm, RetMap, ignore) of
            ignore -> ok;
            NextMonth -> ?IF(?MODULE:month_ending(SrcTime) =:= NextMonth, ?PASS, erlang:throw({error, SrcTime, ?MODULE:month_ending(SrcTime), NextMonth}))
        end,
        case maps:get(bw, RetMap, ignore) of
            ignore -> ok;
            BeginWeek ->
                ?IF(?MODULE:week_beginning(SrcTime) =:= BeginWeek, ?PASS, erlang:throw({error, SrcTime, BeginWeek}))
        end,
        case maps:get(mn, RetMap, ignore) of
            ignore -> ok;
            Midnight ->
                ?IF(?MODULE:zero_timestamp(SrcTime) =:= Midnight, ?PASS, erlang:throw({error, SrcTime, Midnight}))
        end,
        case maps:get(dd1, RetMap, ignore) of
            ignore -> ok;
            DiffDate ->
                ?IF( lists:all(fun({DD, _}=DiffDateBase) ->
                    ?MODULE:diff_days(?MODULE:datetime(SrcTime), DiffDateBase) =:= DiffDate andalso
                        ?MODULE:diff_days(SrcTime, ?MODULE:timestamp(DiffDateBase)) =:= DiffDate andalso
                        ?MODULE:diff_days(?MODULE:date(SrcTime), DD) =:= DiffDate
                               end, DiffDateBases),
                    ?PASS,
                    erlang:throw({error, SrcTime, DiffDate}))
        end,
        %% 下一天的0点，等于当天0点+24小时
        {SrcH, SrcM, SrcS} = SrcDTime,
        DiffMNSec = SrcH*60*60+SrcM*60+SrcS, %% 离0点的秒数
        [begin
             DNextSec = ((DiffH*60*60+DiffM*60+DiffS) - (DiffMNSec)),
             case DNextSec=<0 of
                 true ->
                     %% 已经过了，要算第二天的
                     ?IF( ?MODULE:diff_next_daytime(SrcTime, DiffTime) =:= (SecDay+DNextSec), ?PASS, erlang:throw({error, SrcTime, DiffTime}));
                 _ ->
                     %% 还没到时间
                     ?IF( ?MODULE:diff_next_daytime(SrcTime, DiffTime) =:= DNextSec, ?PASS, erlang:throw({error, SrcTime, DiffTime}))
             end
         end || {DiffH, DiffM, DiffS} = DiffTime <- [{0,0,0}, {6,6,6}, {12,0,0}, {23,59,59}] ]
             end, TimeArray),
    %% 同一天
    SameDayList = [ ?MODULE:timestamp(T) || T <- [{{2022, 7, 1}, {0,0,0}}, {{2022, 7, 1}, {8,0,0}}, {{2022, 7, 1}, {12,0,0}}, {{2022, 7, 1}, {23,59,59}}]],
    [begin
         ?IF(true =:= ?MODULE:is_same_date(Time1, Time2), ?PASS, erlang:throw({error, Time1, Time2})),
         ?IF(true =:= ?MODULE:is_same_week(Time1, Time2), ?PASS, erlang:throw({error, Time1, Time2})),
         ?IF(0 =:= ?MODULE:diff_days(Time2, Time1), ?PASS, erlang:throw({error, Time1, Time2})),
         ?IF(0 =:= ?MODULE:diff_days(Time1, Time2), ?PASS, erlang:throw({error, Time1, Time2}))
     end || Time1 <- SameDayList, Time2 <- SameDayList ],
    %% 同一周，但不同天
    SameWeekList = [ ?MODULE:timestamp(T) || T <- [{{2022, 7, 4}, {0,0,0}}, {{2022, 7, 6}, {8,0,0}}, {{2022, 7, 8}, {12,0,0}}, {{2022, 7, 10}, {23,59,59}}]],
    [begin
         ?IF(false =:= ?MODULE:is_same_date(Time1, Time2), ?PASS, erlang:throw({error, Time1, Time2})),
         ?IF(true =:= ?MODULE:is_same_week(Time1, Time2), ?PASS, erlang:throw({error, Time1, Time2})),
         ?IF(0 =/= ?MODULE:diff_days(Time1, Time2), ?PASS, erlang:throw({error, Time1, Time2})),
         ?IF(0 =/= ?MODULE:diff_days(Time2, Time1), ?PASS, erlang:throw({error, Time1, Time2}))
     end || Time1 <- SameWeekList, Time2 <- SameWeekList, Time1=/=Time2 ],
    SameWeekList2 = [ ?MODULE:timestamp(T) || T <- [{{2022, 7, 11}, {0,0,0}}, {{2022, 7, 13}, {8,0,0}}, {{2022, 7, 15}, {12,0,0}}, {{2022, 7, 17}, {23,59,59}}]],
    [begin
         ?IF(false =:= ?MODULE:is_same_date(Time1, Time2), ?PASS, erlang:throw({error, Time1, Time2})),
         ?IF(false =:= ?MODULE:is_same_week(Time1, Time2), ?PASS, erlang:throw({error, Time1, Time2})),
         ?IF(0 =/= ?MODULE:diff_days(Time1, Time2), ?PASS, erlang:throw({error, Time1, Time2})),
         ?IF(0 =/= ?MODULE:diff_days(Time2, Time1), ?PASS, erlang:throw({error, Time1, Time2}))
     end || Time1 <- SameWeekList, Time2 <- SameWeekList2, Time1=/=Time2 ],
    ok.
