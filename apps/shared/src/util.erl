-module(util).

-export([get_now/0, get_now_us/0, measure/2,
	 pmap/2, binary_to_hex/1, hex_to_binary/1,
	 seed_random/0,
	 iso8601/1, iso8601/2]).

get_now() ->
    {MS, S, SS} = erlang:now(),
    MS * 1000000 + S + SS / 1000000.
    

get_now_us() ->
    {MS, S, SS} = erlang:now(),
    (MS * 1000000 + S) * 1000000 + SS.


measure(Label, F)
  when is_list(Label) ->
    T1 = get_now_us(),
    R = F(),
    T2 = get_now_us(),
    io:format("[~.1fms] ~s~n", [(T2 - T1) / 1000, Label]),
    R;
measure(Label, F) ->
    measure(io_lib:format("~p", [Label]), F).

pmap(F, L) ->
    I = self(),
    Pids =
	[spawn(fun() ->
		       I ! {ok, self(), F(E)}
	       end) || E <- L],
    [receive
	 {ok, Pid, E2} ->
	     E2
     end || Pid <- Pids].

binary_to_hex(<<>>) ->
    [];
binary_to_hex(<<C:8, Bin/binary>>) ->
    iolist_to_binary(
      [io_lib:format("~2.16.0b", [C]) | binary_to_hex(Bin)]
     ).

hex_to_binary(<<>>) ->
    <<>>;
hex_to_binary(<<A:8, B:8, Rest/binary>>) ->
    <<((hex_to_binary1(A) bsl 4) bor hex_to_binary1(B)):8,
      (hex_to_binary(Rest))/binary>>.

hex_to_binary1(C)
  when C >= $0,
       C =< $9 ->
    C - $0;
hex_to_binary1(C)
  when C >= $a,
       C =< $f ->
    C + 10 - $a;
hex_to_binary1(C)
  when C >= $A,
       C =< $F ->
    C + 10 - $A.

seed_random() ->
    {MS, S, SS} = erlang:now(),
    PS = lists:sum(pid_to_list(self())),
    random:seed(MS + PS, S, SS).

%% ISO8601 Date Formatting


iso8601({{Y, Mo, D}, {H, M, S}}) ->
    list_to_binary(
      io_lib:format("~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0BZ",
		    [Y, Mo, D, H, M, trunc(S)])).

iso8601(Local, local) ->
    [Universal | _] = calendar:local_time_to_universal_time_dst(Local),
    if
	Universal < Local ->
	    {0, {TzH, TzM, _}} =
		calendar:time_difference(Universal, Local);
	true ->
	    {0, {TzH1, TzM}} =
		calendar:time_difference(Local, Universal),
	    TzH = -TzH1
    end,
    iso8601(Local, {TzH, TzM});

iso8601(Universal, universal) ->
    iso8601(Universal, {0, 0});

iso8601({{Y, Mo, D}, {H, M, S}}, {TzH, TzM}) ->
    list_to_binary(
      io_lib:format("~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0B~c~2..0B:~2..0B",
		    [Y, Mo, D, H, M, trunc(S),
		     if
			 TzH < 0 -> $-;
			 true -> $+
		     end, abs(TzH), TzM])).

