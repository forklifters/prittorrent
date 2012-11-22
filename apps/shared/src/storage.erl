-module(storage).

%% TODO: relative redirects

-export([make/1, size/1, fold/5, resource_size/1]).

-define(USER_AGENT, "PritTorrent/1.0").
-define(TIMEOUT, 30 * 1000).
-define(PART_SIZE, 32768).
-define(MAX_REDIRECTS, 3).

-record(storage, {urls :: [{binary(), integer()}]}).

%% URLs for multi-file torrents, not fallback
make(URLs) ->
    set_urls(#storage{urls = []}, URLs).

set_urls(Storage, URLs1) ->
    URLs2 = [case URL of
		 {_, Size} when is_integer(Size) ->
		     URL;
		 _ when is_binary(URL) ->
		     case resource_size(URL) of
			 {ok, Size} ->
			     {URL, Size};
			 undefined ->
			     exit(no_content_length)
		     end
	     end || URL <- URLs1],
    Storage#storage{urls = URLs2}.

size(#storage{urls = URLs}) ->
    lists:foldl(fun({_, Size}, Total) ->
			Total + Size
		end, 0, URLs).

resource_size(URL) when is_binary(URL) ->
    resource_size(binary_to_list(URL));
resource_size(URL) ->
    resource_size(URL, 0).

resource_size(_URL, Redirects) when Redirects > ?MAX_REDIRECTS ->
    exit(too_many_redirects);

resource_size(URL, Redirects) ->
    case lhttpc:request(URL, head, [{"User-Agent", ?USER_AGENT}], [], ?TIMEOUT) of
	{ok, {{200, _}, Headers, _}} ->
	    %% HACK: dirty here. find a better place:
	    case extract_header("content-type", Headers) of
		[_ | _] = Type ->
		    model_feeds:hint_enclosure_type(URL, Type);
		_ ->
		    ignore
	    end,

	    case extract_header("content-length", Headers) of
		undefined ->
		    undefined;
		SizeS ->
		    Size = list_to_integer(SizeS),
		    {ok, Size}
	    end;
	{ok, {{Status, _}, Headers, _}}
	 when Status >= 300, Status < 400 ->
	    case extract_header("location", Headers) of
		undefined ->
		    exit({http, Status});
		Location ->
		    io:format("HTTP ~B: ~s redirects to ~s~n", [Status, URL, Location]),
		    resource_size(Location, Redirects + 1)
	    end;
	{ok, {{Status, _}, _, _}} ->
	    error_logger:warning_msg("HTTP ~B~n~s~n", [Status, URL]),
	    exit({http, Status});
	{error, Reason} ->
	    error_logger:warning_msg("~s~n~p~n", [URL, Reason]),
	    exit(Reason)
    end.

fold(_, _, Length, _, AccOut) when Length =< 0 ->
    AccOut;
fold(#storage{urls = URLs} = Storage,
     Offset, Length, F, AccIn) ->
    {URL, Offset1, Length1} =
	lists:foldl(
	  fun({URL, Size}, {look, Offset1}) ->
		  if
		      Offset1 < Size ->
			  {URL, Offset1, min(Length, Size)};
		      true ->
			  {look, Offset1 - Size}
		  end;
	     (_, {URL, Offset1, Length1}) ->
		  {URL, Offset1, Length1}
	  end, {look, Offset}, URLs),

    AccOut = fold_resource(URL, Offset1, Length1, F, AccIn),
    
    fold(Storage, Offset + Length1, Length - Length1, F, AccOut).

%% FIXME: what if response chunk is smaller than requested? retry in
%% case it's still uploading?
fold_resource(URL, Offset, Length, F, AccIn) when is_binary(URL) ->
    fold_resource(binary_to_list(URL), Offset, Length, F, AccIn);
fold_resource(URL, Offset, Length, F, AccIn) ->
    fold_resource(URL, Offset, Length, F, AccIn, 0).

fold_resource(_URL, _Offset, _Length, _F, _AccIn, Redirects)
  when Redirects > ?MAX_REDIRECTS ->
    exit(too_many_redirects);
fold_resource(URL, Offset, Length, F, AccIn, Redirects) ->
    %% Compose request
    ReqHeaders =
        if
            is_integer(Offset),
            is_integer(Length) ->
                [{"Range",
                  io_lib:format("bytes=~B-~B",
                                [Offset,
                                 Offset + Length - 1])
                 }];
            true ->
                []
        end ++
        [{"User-Agent", ?USER_AGENT}],
    ReqOptions =
	[{partial_download,
	  [
	   %% specifies how many part will be sent to the calling
	   %% process before waiting for an acknowledgement
	   {window_size, 4},
	   %% specifies the size the body parts should come in
	   {part_size, ?PART_SIZE}
	  ]}
	],
    case lhttpc:request(URL, get, ReqHeaders,
			[], ?TIMEOUT, ReqOptions) of
	%% Partial Content
	{ok, {{206, _}, _Headers, Pid}} ->
	    %% Strrream:
	    fold_resource1(Pid, F, AccIn);
	{ok, {{Status, _}, Headers, Pid}}
	  when Status >= 300, Status < 400 ->
	    %% Finalize this response:
	    fold_resource1(Pid, fun(_, _) ->
					ok
				end, undefined),

	    case extract_header("location", Headers) of
		undefined ->
		    exit({http, Status});
		Location ->
		    io:format("HTTP ~B: ~s redirects to ~s~n", [Status, URL, Location]),
		    %% FIXME: this breaks Offset & Length for multi-file torrents
		    fold_resource(Location, Offset, Length, F, AccIn, Redirects + 1)
	    end;
	{ok, {{Status, _}, _Headers, Pid}} ->
	    %% Finalize this response:
	    exit(Pid, kill),

	    exit({http, Status});
	{error, Reason} ->
	    exit(Reason)
    end.

fold_resource1(undefined, _, AccIn) ->
    %% No body, no fold.
    AccIn;
fold_resource1(Pid, F, AccIn) ->
    case (catch lhttpc:get_body_part(Pid, ?TIMEOUT)) of
	{ok, Data} when is_binary(Data) ->
	    AccOut = F(AccIn, Data),
	    fold_resource1(Pid, F, AccOut);
	{ok, {http_eob, _Trailers}} ->
	    AccIn;
	{'EXIT', Reason} ->
	    error_logger:error_msg("storage fold interrupted: ~p~n", [Reason]),
	    AccIn;
	{error, Reason} ->
	    error_logger:error_msg("storage fold interrupted: ~p~n", [Reason]),
	    AccIn
    end.

extract_header(Name1, Headers) ->
    Name2 = string:to_lower(Name1),
    lists:foldl(
      fun({Header, Value}, undefined) ->
	      case string:to_lower(Header) of
		  Name3 when Name2 == Name3 ->
		      Value;
		  _ ->
		      undefined
	      end;
	 (_, Value) ->
	      Value
      end, undefined, Headers).
    
