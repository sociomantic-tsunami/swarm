### Fix synchronization for RecordStream

`src/swarm/util/RecordStream.d`

The stream must be only suspended if the method suspend has been currently
called.
This is required since ISuspendableThrottler (from ocean v5) ensures that
the suspend state of an ISuspendable instance when added to a throttler is
consistent with the throttler state.
Without this patch-fix if a RecordStream is added as suspendable to
a throttler then it will try to process the stream because `suspended()`
was checking for the running state of the fiber and that would make an
application  crash in the best case or having unexpected behaviour.
To avoid this situation the `suspended()` implementation now only
checks if the stream is suspended meaning that suspend() has been
currently called.
