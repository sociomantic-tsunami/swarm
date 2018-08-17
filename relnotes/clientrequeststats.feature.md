### Client stats loggin enhancements

`swarm.neo.client.mixins.ClientCore`

The `log` method of `RequestStatsTemplate` now accepts a second argument: a
settings struct that allows the user to specify the information that is logged.
The following options now exist:
* `LogSettings.occurred_only`: If true, only log stats for requests that have
  occurred at least once in the lifetime of this program; if false, log stats
  for all requests.
* `LogSettings.timing_histogram`: If true, log the full timing histogram; if
  false, log just count and total time.

