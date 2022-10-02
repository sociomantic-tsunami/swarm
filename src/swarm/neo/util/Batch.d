/*******************************************************************************

    Record batch creator/extractor, with optional compression

    Design considerations:
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

    copyright: Copyright (c) 2017 dunnhumby Germany GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module swarm.neo.util.Batch;

import ocean.meta.types.Qualifiers;
import ocean.core.Verify;
import ocean.io.compress.Lzo;
import ocean.meta.traits.Basic : ArrayKind, isArrayType;
import ocean.meta.traits.Indirections : hasIndirections;
import ocean.meta.types.Arrays : ElementTypeOf;

/*******************************************************************************

    Record batch creator.

    Params:
        Record = tuple of types of which a record consists

*******************************************************************************/

public struct BatchWriter ( Record ... )
{
    static assert(recordFieldsSupported!(Record)());

    /// Batch buffer. Set by calling `initialise`.
    private void[]* buffer;

    /// Batch / record size limit. Used in two circumstances: 1. to check the
    /// size of a record being added; 2. once a batch exceeds this size, it is
    /// considered full.
    private size_t max_size;

    /***************************************************************************

        Initializes this instance with the specified backing buffer and size.
        Any content in the buffer is cleared.

        Params:
            buffer = backing buffer to use to build up batches
            max_size = batch / record size limit

    ***************************************************************************/

    public void initialise ( void[]* buffer, size_t max_size )
    {
        this.buffer = buffer;
        this.max_size = max_size;
        this.clear();
    }

    /***************************************************************************

        Calculates the number of bytes that the specified record will take in
        the batch.

        Params:
            record = tuple of record fields

        Returns:
            the number of bytes that would be consumed in the batch by the
            record

    ***************************************************************************/

    public size_t sizeOf ( Record record )
    {
        size_t sum;
        foreach ( field; record )
            sum += this.sizeOfField(field);

        return sum;
    }

    /***************************************************************************

        Tells whether the specified record would be allowed to be added to the
        batch.

        Params:
            record = tuple of record fields

        Returns:
            true if the record could be added to the batch

    ***************************************************************************/

    public bool fits ( Record record )
    {
        return this.sizeOf(record) <= this.max_size;
    }

    /***************************************************************************

        Adds the specified record to the batch, if it fits, and calls the
        provided delegate, if the batch is full as a result of adding the new
        record.

        Params:
            record = tuple of record fields
            batch_finished = delegate called when the batch is full. This
                delegate must do whatever is required with the finished batch.
                After the delegate returns, the batch is cleared.

        Returns:
            true if the record was added, false if it was too big

    ***************************************************************************/

    public bool add ( Record record, scope void delegate ( ) batch_finished )
    {
        if ( !this.fits(record) )
            return false;

        foreach ( field; record )
            this.addField(field);

        if ( (*this.buffer).length >= this.max_size )
        {
            batch_finished();
            this.clear();
        }

        return true;
    }

    /***************************************************************************

        Returns:
            a slice of the data in the batch

    ***************************************************************************/

    public const(void)[] get ( )
    {
        return *this.buffer;
    }

    /***************************************************************************

        Compresses the data in the batch using the provided LZO instance and
        destination buffer.

        Params:
            lzo = LZO instance to use for compression
            compress_buf = buffer to receive compressed batch

        Returns:
            a slice of the compressed data in compress_buf

    ***************************************************************************/

    public const(void)[] getCompressed ( Lzo lzo, ref void[] compress_buf )
    {
        // Set destination to max possible length.
        compress_buf.length =
            lzo.maxCompressedLength((*this.buffer).length) + size_t.sizeof;
        assumeSafeAppend(compress_buf);

        // Write uncompressed length into first size_t.sizeof bytes of dest.
        *(cast(size_t*)(compress_buf.ptr)) = (*this.buffer).length;

        // Compress into destination.
        auto dst = compress_buf[size_t.sizeof .. $];
        auto compressed_len = lzo.compress(*this.buffer, dst);

        // Minimize dest length and return.
        compress_buf.length = compressed_len + size_t.sizeof;
        assumeSafeAppend(compress_buf);
        return compress_buf;
    }

    /***************************************************************************

        Removes all records from the batch.

    ***************************************************************************/

    public void clear ( )
    {
        (*this.buffer).length = 0;
        assumeSafeAppend(*this.buffer);
    }

    /***************************************************************************

        Calculates the size in the batch required by a single record field.

        Params:
            Field = type of field
            field = field to calculate batched size of

        Returns:
            the number of bytes the specified field would consume in the batch

    ***************************************************************************/

    private size_t sizeOfField ( Field ) ( Field field )
    {
        static if ( isArrayType!(Field) == ArrayKind.Dynamic )
            return size_t.sizeof +
                (field.length * ElementTypeOf!(Field).sizeof);
        else
            return Field.sizeof;
    }

    /***************************************************************************

        Adds a single record field to the batch.

        Params:
            Field = type of field
            field = field to add to the batch

    ***************************************************************************/

    private void addField ( Field ) ( Field field )
    {
        static if ( isArrayType!(Field) == ArrayKind.Dynamic )
        {
            auto len = field.length;
            this.addBytes((cast(void*)&len)[0 .. size_t.sizeof]);
            this.addBytes(field[]);
        }
        else
            this.addBytes((cast(void*)&field)[0 .. Field.sizeof]);
    }

    /***************************************************************************

        Adds the specified bytes to the batch.

        Params:
            data = slice of data to add to the batch

    ***************************************************************************/

    private void addBytes ( in void[] data )
    {
        *(this.buffer) ~= data;
    }
}

/*******************************************************************************

    Record batch extractor.

    Params:
        Record = tuple of types of which a record consists

*******************************************************************************/

public class BatchReader ( Record ... )
{
    import ocean.core.Enforce;

    static assert(recordFieldsSupported!(Record)());

    /// Unconsumed data remaining in batch. Slice of batch passed to ctor.
    private const(void)[] remaining;

    /***************************************************************************

        Constructor. Sets this instance to extract non-compressed data from the
        specified batch.

        Params:
            batch = BatchWriter-created batch to extract records from. The
                buffer must remain unmodified and accessible for the lifetime of
                this instance

    ***************************************************************************/

    public this ( in void[] batch )
    {
        this.remaining = batch;
    }

    /***************************************************************************

        Constructor. Sets this instance to extract compressed data from the
        specified batch.

        Params:
            lzo = LZO instance to use for decompression
            batch = BatchWriter-created batch to extract records from
            decompress_buf = buffer into which the batch is uncompressed. The
                buffer must remain unmodified and accessible for the lifetime of
                this instance

        Throws:
            Exception if batch is too short (if it can't contain the batch
            length), ocean.io.compress.CompressException.CompressException if
            decompressing failed due to the decompress buffer overflow.

    ***************************************************************************/

    public this ( Lzo lzo, in void[] batch, ref void[] decompress_buf )
    {
        enforce(batch.length >= size_t.sizeof,
            "Batch too short to contain uncompressed length");

        // Read uncompressed length from first size_t.sizeof bytes.
        auto uncompressed_len = *(cast(size_t*)(batch.ptr));
        decompress_buf.length = uncompressed_len;
        assumeSafeAppend(decompress_buf);

        // Decompress into decompress_buf.
        auto src = batch[size_t.sizeof .. $];
        auto final_uncompressed_len = lzo.decompressSafe(src, decompress_buf);
        verify(final_uncompressed_len == uncompressed_len);

        // Construct as normal, extracting from the decompressed data.
        this(decompress_buf);
    }

    /***************************************************************************

        Extraction iterator. Extracts records from the batch one at a time and
        passes them to the iteration delegate.

        Params:
            dg = opApply iteration delegate

        Returns:
            0 if the iteration finished or non-0 if it was broken by the called

    ***************************************************************************/

    public int opApply ( scope int delegate ( ref Record ) dg )
    {
        Record record;
        while ( this.remaining.length )
        {
            foreach ( ref field; record )
                this.extractField(field);

            if ( auto r = dg(record) )
                return r;
        }

        return 0;
    }

    /***************************************************************************

        Extracts a single field from the batch.

        Params:
            Field = type of field
            field = field to extract from batch (passed by reference; value is
                extracted directly into this argument)

    ***************************************************************************/

    private void extractField ( Field ) ( ref Field field )
    {
        static if ( isArrayType!(Field) == ArrayKind.Dynamic )
        {
            auto len = this.extractBytes(size_t.sizeof);
            field = cast(Field)this.extractBytes(*(cast(size_t*)len.ptr));
        }
        else
        {
            auto slice = (cast(void*)&field)[0..Field.sizeof];
            slice[] = this.extractBytes(Field.sizeof)[];
        }
    }

    /***************************************************************************

        Consumes the specified number of bytes from the batch.

        Params:
            bytes = number of bytes to consume

        Returns:
            a slice of the consumed bytes

    ***************************************************************************/

    private const(void)[] extractBytes ( size_t bytes )
    {
        enforce(this.remaining.length >= bytes);

        auto ret = this.remaining[0 .. bytes];
        this.remaining = this.remaining[bytes .. $];
        return ret;
    }
}

/*******************************************************************************

    Helper function to statically validate that a record tuple is of supported
    types:
        * Array elements must not have indirections. (This means that only 1d
          arrays are allowed.)
        * Non-array fields may not contain indirections.

    Params:
        Record = tuple of types of which a record consists

    Returns:
        true if all fields of Record are supported

*******************************************************************************/

private bool recordFieldsSupported ( Record ... ) ( )
{
    foreach ( Field; Record )
    {
        static if ( isArrayType!(Field) == ArrayKind.Dynamic )
        {
            static if ( hasIndirections!(ElementTypeOf!(Field)) )
                return false;
        }
        else
        {
            static if ( hasIndirections!(Field) )
                return false;
        }
    }

    return true;
}

version ( unittest )
{
    import ocean.core.Test;

    /// Enum of expected test results, used by `checkAdd`.
    enum ExpectedResult
    {
        Added,
        TooBig,
        Sent
    }

    /// Adds the specified field to the batch and checks the result.
    void checkAdd ( Field ) ( string test_name, BatchWriter!(Field) batch,
        Field field, size_t expected_length,
        ExpectedResult expected = ExpectedResult.Added )
    {
        auto t = new NamedTest(test_name);
        bool sent;
        auto added = batch.add(field,
            {
                sent = true;
            }
        );

        with ( ExpectedResult ) switch ( expected )
        {
            case Added:
                t.test(added);
                t.test!("==")(batch.get.length, expected_length);
                t.test(!sent);
                break;

            case TooBig:
                t.test(!added);
                t.test(!sent);
                break;

            case Sent:
                t.test(added);
                t.test!("==")(batch.get.length, expected_length);
                t.test(sent);
                break;

            default: assert(false);
        }
    }
}

// Tests for adding record to a batch.
unittest
{
    void[] buffer;
    static immutable max_len = 256;

    {
        BatchWriter!(uint) batch;
        batch.initialise(&buffer, max_len);
        uint i;
        checkAdd("Add a uint", batch, i, uint.sizeof);
    }

    {
        BatchWriter!(cstring) batch;
        batch.initialise(&buffer, max_len);
        auto str = "hello"[];
        checkAdd("Add a short string", batch, str, size_t.sizeof + str.length);
    }

    {
        BatchWriter!(ubyte[]) batch;
        batch.initialise(&buffer, max_len);
        auto data = new ubyte[max_len - size_t.sizeof];
        checkAdd("Add and send an array at the size limit",
            batch, data, 0, ExpectedResult.Sent);
    }

    {
        BatchWriter!(ubyte[]) batch;
        batch.initialise(&buffer, max_len);
        auto data1 = new ubyte[max_len - size_t.sizeof - 1];
        checkAdd("Add an array just under the size limit",
            batch, data1, size_t.sizeof + data1.length);
        auto data2 = new ubyte[1];
        checkAdd("Add a byte, filling the batch and causing it to be sent",
            batch, data2, 0, ExpectedResult.Sent);
    }

    {
        BatchWriter!(ubyte[]) batch;
        batch.initialise(&buffer, max_len);
        auto data = new ubyte[max_len - size_t.sizeof + 1];
        checkAdd("Add an array over the size limit",
            batch, data, 0, ExpectedResult.TooBig);
    }
}

// Test creating and extracting a batch of strings.
unittest
{
    void[] buffer;

    auto values = ["best", "thing", "ever"];

    static immutable max_len = 256;
    BatchWriter!(cstring) batcher;
    batcher.initialise(&buffer, max_len);

    foreach ( v; values )
        batcher.add(v, {});

    scope batch = new BatchReader!(cstring)(batcher.get());
    size_t i;
    foreach ( field; batch )
    {
        test!("==")(field, values[i]);
        i++;
    }
}

// Test creating and extracting a batch of strings, with compression.
unittest
{
    auto lzo = new Lzo;
    void[] buffer;

    auto values = ["best", "thing", "ever"];

    static immutable max_len = 256;
    BatchWriter!(cstring) batcher;
    batcher.initialise(&buffer, max_len);

    foreach ( v; values )
        batcher.add(v, {});

    void[] compress_buf, decompress_buf;
    auto compressed = batcher.getCompressed(lzo, compress_buf);
    scope batch = new BatchReader!(cstring)(lzo, compressed, decompress_buf);
    size_t i;
    foreach ( field; batch )
    {
        test!("==")(field, values[i]);
        i++;
    }
}

// Test creating and extracting a batch of <hash_t, string>.
unittest
{
    void[] buffer;

    struct KeyValue
    {
        hash_t key;
        string value;
    }
    KeyValue[] values = [KeyValue(12, "hi"), KeyValue(23, "bye"),
        KeyValue(34, "whatever")];

    {
        static immutable max_len = 256;
        BatchWriter!(typeof(KeyValue.tupleof)) batch;
        batch.initialise(&buffer, max_len);

        foreach ( kv; values )
            batch.add(kv.key, kv.value, {});
    }

    scope batch = new BatchReader!(typeof(KeyValue.tupleof))(buffer);
    size_t i;
    foreach ( key, value; batch )
    {
        test!("==")(key, values[i].key);
        test!("==")(value, values[i].value);
        i++;
    }
}
