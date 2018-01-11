## New method to reset client cumulative stats counters

`swarm.neo.client.mixins.ClientCore`

The new `reset` method of the client core `Stats` class resets all internal
cumulative counters for the client. When writing stats to a log file, it is
recommended to call this method once per stats logging cycle, after writing to
the log.

