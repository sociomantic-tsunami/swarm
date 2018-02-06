## Specifying a batch size in `RecordBatch`'s ctor no longer allowed

`swarm.util.RecordBatcher`

The optional constructor argument `batch_size` is deprecated. Any code that uses
this argument should be adapted to use the other constructor. `RecordBatch` will
internally adapt to the size of incoming batches.

