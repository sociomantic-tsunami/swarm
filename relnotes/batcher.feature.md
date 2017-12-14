## New, more flexible record batch creator / extractor

`swarm.neo.util.Batch`

The new record batcher is designed as a replacement of the classes in
`swarm.util.RecordBatcher`, with the following enhancements:
    1. No heap allocations are required to initialise an instance.
    2. The methods to add records to / extract records from a batch are
        templated, allowing any type tuples to be used. (Only 1d arrays and
        value types are allowed.)
    3. Compression is built in but optional. An LZO instance is only
        required by the methods that deal with de/compression.
    4. The maximum batch size in the batch creator is set at run-time and is
        a "soft" limit. As long as each record is smaller, in total, that the
        maximum batch size, it is considered to fit. This approach simplifies
        things when reading from the storage engine is a destructive
        operation -- the record can still be added to the batch, even if it
        takes the batch as a whole over the maximum size.
    5. The batch extractor has no concept of a maximum batch size.

