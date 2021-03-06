-module(feeds_update).

-export([start_link/0, update_loop/0, update/1]).

-include_lib("model/include/model.hrl").

-define(INTERVAL, 600).

start_link() ->
    {ok, spawn_link(fun update_loop/0)}.

update_loop() ->
    case model_feeds:to_update(?INTERVAL) of
	{ok, {URL, Delay}}
	  when Delay =< 0 ->
	    io:format("Update ~s (scheduled in ~.2fs)~n", [URL, Delay]),
	    case (catch update(URL)) of
		{'EXIT', Reason} ->
		    error_logger:error_msg("Error updating ~s:~n~p~n", [URL, Reason]);
		_ ->
		    ok
	    end;
	{ok, {_, Delay}} ->
	    io:format("Nothing to update, sleeping ~.2f...~n", [Delay]),
	    receive
	    after trunc(Delay * 1000) ->
		    ok
	    end
    end,
    
    ?MODULE:update_loop().


update(URL) when is_binary(URL) ->
    update(binary_to_list(URL));
update(URL) ->
    {ok, Etag1, LastModified1} = model_feeds:prepare_update(URL),
    spawn(fun() ->
		  case (catch update1(URL, Etag1, LastModified1)) of
		      {'EXIT', Reason} ->
			  error_logger:error_msg("feeds update failed for ~s~n~p~n", [URL, Reason]);
		      _ ->
			  ok
		  end
	  end),
    ok.

update1(URL, Etag1, LastModified1) ->
    NormalizeURL = fun(undefined) ->
			   undefined;
		      (URL1) ->
			   url:join(URL, URL1)
		   end,
    R1 =
	try feeds_fetch:fetch(URL, Etag1, LastModified1) of
	    {ok, {Etag, LastModified}, FeedEl} ->
		try
		    {ok, Items1} =
			feeds_parse:pick_items(FeedEl),
		    io:format("Picked ~b items from feed ~s~n",
			      [length(Items1), URL]),
		    FeedXml1 = iolist_to_binary(feeds_parse:serialize(FeedEl)),
		    ChannelEl = case feeds_parse:get_channel(FeedEl) of
				    undefined ->
					exit(invalid_feed);
				    ChannelEl1 ->
					ChannelEl1
				end,
		    Title1 = feeds_parse:title(ChannelEl),
		    Lang1 = feeds_parse:lang(ChannelEl),
		    Summary1 = feeds_parse:summary(ChannelEl),
		    Homepage1 = NormalizeURL(feeds_parse:link(ChannelEl)),
		    Image1 = NormalizeURL(feeds_parse:image(ChannelEl)),
		    Items2 =
			lists:foldl(
			  fun(ItemXml, Items2) ->
				  try xml_to_feed_item(URL, NormalizeURL, ItemXml) of
				      #feed_item{} = Item1 ->
					  %% Fill in image
					  Item2 = case Item1 of
						      #feed_item{image = <<_:8, _/binary>>} ->
							  Item1;
						      _ ->
							  Item1#feed_item{image = Image1}
						  end,
					  %% Fill in lang
					  Item3 = case Item2 of
						      #feed_item{lang = <<_:8, _/binary>>} ->
							  Item2;
						      _ ->
							  Item2#feed_item{lang = Lang1}
						  end,
					  [Item3 | Items2];
				      _ ->
					  %%io:format("Malformed item: ~s~n", [exmpp_xml:document_to_binary(ItemXml)]),
					  Items2
				  catch exit:Reason ->
					  error_logger:warning_msg("Cannot extract from feed item: ~s~n~p~n~s~n", [URL, Reason, ItemXml]),
					  Items2
				  end
			  end, [], Items1),
		    if
			length(Items2) < length(Items1) ->
			    error_logger:warning_msg("Lost ~B of ~B items of ~s~n",
				      [length(Items1) - length(Items2), length(Items1), URL]);
			true ->
			    ok
		    end,
		    {ok, {Etag, LastModified},
		     FeedXml1,
		     Title1, Lang1, Summary1, Homepage1, Image1,
		     lists:reverse(Items2)}
		catch exit:Reason1 ->
			{error, {Etag, LastModified}, Reason1}
		end;
	    not_modified ->
		%% Well, show it to the user... (in green :)
		{error, {Etag1, LastModified1}, not_modified};
	    {error, Reason1} ->
		{error, {Etag1, LastModified1}, Reason1}
	catch exit:Reason1 ->
		error_logger:error_msg("fetching ~s failed:~n~p~n", [URL, Reason1]),
		{error, {Etag1, LastModified1}, Reason1}
	end,

    case R1 of
	{ok, {Etag2, LastModified2},
	 FeedXml,
	 Title2, Lang2, Summary2, Homepage2, Image2,
	 Items3} ->
	    model_feeds:write_update(URL, {Etag2, LastModified2},
				     null, FeedXml,
				     Title2, Lang2, Summary2, Homepage2, Image2,
				     Items3),
	    ok;
	%% HTTP 304 Not Modified:
	{error, {Etag2, LastModified2},
	 {http, 304}} ->
	    model_feeds:write_update(URL, {Etag2, LastModified2},
				     not_modified, null,
				     null, null, null, null, null,
				     []),
	    ok;
	{error, {Etag2, LastModified2}, Reason} ->
	    Error = case Reason of
		undefined -> null;
		_ -> list_to_binary(io_lib:format("~p",[Reason]))
	    end,
	    model_feeds:write_update(URL, {Etag2, LastModified2},
				     Error, null,
				     null, null, null, null, null,
				     []),
	    {error, Reason}
    end.

xml_to_feed_item(Feed, NormalizeURL, Xml) ->
    Id = feeds_parse:item_id(Xml),
    Title = feeds_parse:item_title(Xml),
    Lang = feeds_parse:item_lang(Xml),
    Summary = feeds_parse:item_summary(Xml),
    Published = feeds_parse:item_published(Xml),
    Homepage = NormalizeURL(feeds_parse:item_link(Xml)),
    Payment = NormalizeURL(feeds_parse:item_payment(Xml)),
    Image = NormalizeURL(feeds_parse:item_image(Xml)),
    Enclosures = lists:map(
		   fun({Enclosure, EnclosureType, EnclosureTitle, EnclosureGUID1}) ->
                           EnclosureGUID2 =
                               if
                                   is_binary(EnclosureGUID1) -> EnclosureGUID1;
                                   true -> Id  %% Fallback to item id
                               end,
			   {NormalizeURL(Enclosure), EnclosureType, EnclosureTitle, EnclosureGUID2}
		   end,
		   feeds_parse:item_enclosures(Xml)),
    if
	is_binary(Id),
	is_binary(Title),
	is_binary(Published) ->
	    #feed_item{feed = Feed,
		       id = Id,
		       title = Title,
		       lang = Lang,
		       summary = Summary,
		       published = Published,
		       homepage = Homepage,
		       payment = Payment,
		       image = Image,
		       enclosures = Enclosures};
	true ->
	    %% Drop this
	    null
    end.


