### Specifying a batch size in `RecordBatch`'s ctor no longer allowed

`swarm.util.RecordBatcher`

The `RecordBatch` class no longer has any concept of a maximum batch size. It
will simply adapt to the size of an incoming batch.

The optional constructor argument `batch_size` is deprecated. Any code that uses
this argument should be adapted to use the other constructor. `RecordBatch` will
internally adapt to the size of incoming batches.

The constant `RecordBatch.DefaultMaxBatchSize` is deprecated. Any usages should
be removed.

