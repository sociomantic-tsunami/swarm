* `swarm.node.request.RequestStats`

  The `init` method of `RequestStats` now accepts an additional bool argument,
  `timing`, which defaults to true. If false is passed to this argument, timing
  stats will not be tracked for this request type.

  When iterating over the stats (i.e. `RequestStats.request_stats`), it is
  possible to tell whether a request has timing stats tracked by attempting a
  dynamic cast to `ISingleRequestStatsWithTiming`
  (`auto timed_stats = cast(ISingleRequestStatsWithTiming)stats;`). If the cast
  returns non-null, then timing stats for the request have been gathered.
  Otherwise, timing stats have not been gathered and just the methods of
  `ISingleRequestStats` may be used for that request type.

