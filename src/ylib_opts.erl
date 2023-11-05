%%%-------------------------------------------------------------------
%%% @doc
%%% @end
%%%-------------------------------------------------------------------
-module(ylib_opts).
-export([
    parse_opts/1,
    parse_opts/2,
    parse_opts/3
]).
-export([
    get_opt_val/2
]).

%% @doc
-define(DEFAULT_OPTS, #{opt_format => [], auto_opt => false, atom_key => false, return => map}).
-record(opt_format, {key, val_format, val_single, val_num_min, val_num_max}).

parse_opts(StrList) ->
    parse_opts(StrList, #{auto_opt => true}).
parse_opts(StrList, Opts) when erlang:is_map(Opts) ->
    parse_opts2(StrList, parse_opts_format(Opts));
parse_opts(StrList, OptsFormat) ->
    parse_opts(StrList, #{opt_format => OptsFormat}).
parse_opts(StrList, OptsFormat, Opts) ->
    parse_opts(StrList, Opts#{opt_format => OptsFormat}).

parse_opts_format(#{} = Opts0) ->
    Opts = maps:merge(?DEFAULT_OPTS, Opts0),
    #{opt_format := OptFormat0} = Opts,
    OptFormatList =
        if
            erlang:is_list(OptFormat0) -> OptFormat0;
            erlang:is_map(OptFormat0) -> maps:to_list(OptFormat0);
            true -> erlang:throw({error, OptFormat0})
        end,
    NewOptFormat =
        [begin
             OptFormat =
                 case Format of
                     [ValFormat] -> #opt_format{key=string:trim(Key), val_single=false, val_num_min=0, val_num_max=999, val_format=ValFormat};
                     [ValFormat, Num] -> #opt_format{key=string:trim(Key), val_single=false, val_num_min=Num, val_num_max=Num, val_format=ValFormat};
                     [ValFormat, NumMin, NumMax] -> #opt_format{key=string:trim(Key), val_single=false, val_num_min=NumMin, val_num_max=NumMax, val_format=ValFormat};
                     [] -> #opt_format{key=string:trim(Key), val_num_min=0, val_num_max=0};
                     ValFormat -> #opt_format{key=string:trim(Key), val_single=true, val_num_min=1, val_num_max=1, val_format=ValFormat}
                 end,
             {OptFormat#opt_format.key, OptFormat}
         end || {Key, Format} <- OptFormatList],
    Opts#{opt_format := maps:from_list(NewOptFormat)}.

parse_opts2(StrList, Opts) ->
    {OptAcc, ArgAcc} = parse_opts3(StrList, maps:get(opt_format, Opts), [], [], maps:get(auto_opt, Opts)),
    parse_opts_return(OptAcc, ArgAcc, Opts).

parse_opts3([], _OptsFormat, OptAcc, ArgAcc, _AutoOpt) ->
    {OptAcc, ArgAcc};
parse_opts3([Str | StrList], OptsFormat, OptAcc, ArgAcc, AutoOpt) ->
    case Str of
        "-" ++ _ ->
            {OptVals, NewStrList} =
                case maps:get(Str, OptsFormat, false) of
                    #opt_format{}=OptFormat ->
                        get_opt_val(StrList, OptFormat);
                    false when AutoOpt ->
                        get_opt_val(StrList);
                    false ->
                        erlang:throw({error, {Str, "opt error"}})
            end,
            parse_opts3(NewStrList, OptsFormat, [{Str, OptVals}|OptAcc], ArgAcc, AutoOpt);
        _ ->
            parse_opts3(StrList, OptsFormat, OptAcc, [Str|ArgAcc], AutoOpt)
    end.

get_opt_val(StrList) ->
    get_opt_val(StrList, 0, 999, 0, any, []).
get_opt_val(StrList, #opt_format{val_single=true, val_num_min=NumMin, val_num_max=NumMax, val_format=ValFormat}) ->
    {[OptVal], NewStrList} = get_opt_val(StrList, NumMin, NumMax, 0, ValFormat, []),
    {OptVal, NewStrList};
get_opt_val(StrList, #opt_format{val_single=false, val_num_min=NumMin, val_num_max=NumMax, val_format=ValFormat}) ->
    get_opt_val(StrList, NumMin, NumMax, 0, ValFormat, []).
get_opt_val(["-" ++ _|_] = StrList, NumMin, _NumMax, Num, _ValFormat, ValList) ->
    case Num>=NumMin of
        true ->
            {lists:reverse(ValList), StrList};
        _ ->
            erlang:throw({error, {StrList, NumMin, _NumMax, Num, _ValFormat, ValList}})
    end;
get_opt_val(StrList, _NumMin, NumMax, Num, _ValFormat, ValList) when Num>=NumMax ->
    {lists:reverse(ValList), StrList};
get_opt_val(StrList, NumMin, NumMax, Num, ValFormat, ValList) when Num<NumMax ->
    case get_format_val(StrList, ValFormat) of
        {ok, Val, NewStrList} ->
            get_opt_val(NewStrList, NumMin, NumMax, Num+1, ValFormat, [Val|ValList]);
        false when Num>=NumMin ->
            {lists:reverse(ValList), StrList};
        false ->
            erlang:throw({error, {StrList, NumMin, NumMax, Num, ValFormat, ValList}})
    end.
get_format_val([], _ValFormat) ->
    false;
get_format_val([Str|StrList], ValFormat) when erlang:is_atom(ValFormat) ->
    {ok, get_val(ValFormat, Str), StrList};
get_format_val(StrList, ValFormat) when erlang:is_tuple(ValFormat) ->
    TupleSize = erlang:tuple_size(ValFormat),
    get_tuple_val(StrList, ValFormat, 1, TupleSize, []);
get_format_val(StrList, ValFormat) when erlang:is_list(ValFormat) ->
    get_list_val(StrList, ValFormat, []).

get_tuple_val(StrList, ValFormat, Index, TupleSize, Acc) when Index=<TupleSize ->
    SubValFormat = erlang:element(Index, ValFormat),
    case get_format_val(StrList, SubValFormat) of
        {ok, V, NewStrList} ->
            get_tuple_val(NewStrList, ValFormat, Index+1, TupleSize, [V|Acc]);
        false ->
            false
    end;
get_tuple_val(StrList, _ValFormat, _Index, _TupleSize, Acc) ->
    {ok, erlang:list_to_tuple(lists:reverse(Acc)), StrList}.

get_list_val(StrList, [], Acc) ->
    {ok, lists:reverse(Acc), StrList};
get_list_val(StrList, [SubValFormat|ValFormat], Acc) ->
    case get_format_val(StrList, SubValFormat) of
        {ok, V, NewStrList} ->
            get_list_val(NewStrList, ValFormat, [V|Acc]);
        false ->
            false
    end.

get_val(any, Str) -> Str;
get_val(undefined, Str) -> Str;
get_val(val, Str) -> erlang:list_to_integer(Str);
get_val(int, Str) -> erlang:list_to_integer(Str);
get_val(atom, Str) -> erlang:list_to_atom(Str);
get_val(bin, Str) -> erlang:list_to_binary(Str);
get_val(str, Str) -> Str;
get_val(bool, Str) -> string:lowercase(Str) =:= "true";
get_val(_, Str) -> Str.

parse_opts_return(OptAcc, ArgAcc, Opts) ->
    {Opts1, Args1, DefaultKey} =
        case maps:get(atom_key, Opts) of
            true ->
                NewOptAcc =
                    lists:foldl(fun({Str, NewOptArgs}, Acc) ->
                        NewStr =
                            case Str of
                                [$-,$-|RemStr] -> erlang:list_to_atom(RemStr);
                                [$-|RemStr] -> erlang:list_to_atom(RemStr)
                            end,
                        [{NewStr, NewOptArgs}|Acc]
                                end, [], OptAcc),
                {NewOptAcc, lists:reverse(ArgAcc), default};
            _ ->
                {lists:reverse(OptAcc), lists:reverse(ArgAcc), "--default"}
        end,
    case maps:get(return, Opts, false) of
        false ->
            {Opts1, Args1};
        list when Args1 =/=[] ->
            [{DefaultKey, Args1}|Opts1];
        list ->
            Opts1;
        map when Args1 =/=[] ->
            maps:from_list([{DefaultKey, Args1}|Opts1]);
        map ->
            maps:from_list(Opts1)
    end.