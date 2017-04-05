/*******************************************************************************

    Record batch creator/extractor classes, used to send & receive compressed
    batches of records, thus reducing the network bandwidth required.

    copyright:      Copyright (c) 2012-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.util.RecordBatcher;



/*******************************************************************************

    Imports

*******************************************************************************/

import ocean.util.container.AppendBuffer;

import ocean.io.compress.Lzo;

import ocean.transition;


/*******************************************************************************

    Base class for record batch creator/extractor.

*******************************************************************************/

private abstract class RecordBatchBase
{
    /***************************************************************************

        Maximum uncompressed batch size.

    ***************************************************************************/

    public const DefaultMaxBatchSize = 64 * 1024;


    /***************************************************************************

        Buffer used to store/extract batch of records.

    ***************************************************************************/

    protected AppendBuffer!(ubyte) batch;


    /***************************************************************************

        Lzo instance (passed in constructor).

    ***************************************************************************/

    protected Lzo lzo;


    /***************************************************************************

        Batch size for this instance

    ***************************************************************************/

    protected Const!(size_t) batch_size;

    /***************************************************************************

        Constructor.

        Params:
            lzo = lzo de/compressor to use
            batch_size = batch size to use

    ***************************************************************************/

    protected this ( Lzo lzo, size_t batch_size = DefaultMaxBatchSize )
    {
        this.lzo = lzo;
        this.batch_size = batch_size;
        this.batch = new AppendBuffer!(ubyte)(this.batch_size);
    }


    /***************************************************************************

        Empties the batch.

    ***************************************************************************/

    public void clear ( )
    {
        this.batch.length = 0;
    }


    /***************************************************************************

        Returns the current batch size.

        Returns:
            current batch size

    ***************************************************************************/

    public size_t length ( )
    {
        return this.batch.length;
    }
}



/*******************************************************************************

    Class to create and compress batches. A batch always has a fixed maximum
    size, after which no more records may be added to it.

    The add() method should be called repeatedly until either there is no more
    data to add or the value BatchFull is returned. At this point the compress()
    method can be called, which compresses the batch into a provided buffer, and
    clears the batch for re-use.

*******************************************************************************/

public class RecordBatcher : RecordBatchBase
{
    /***************************************************************************

        Result codes for add() methods.

    ***************************************************************************/

    public enum AddResult
    {
        None,       // default / invalid code
        Added,      // record was added to batch
        BatchFull,  // record not added to batch as currently not enough space
        TooBig      // record not added to batch as bigger than whole buffer
    }


    /***************************************************************************

        Constructor.

        Params:
            lzo = lzo de/compressor to use
            batch_size = batch size to use

    ***************************************************************************/

    public this ( Lzo lzo, size_t batch_size = DefaultMaxBatchSize )
    {
        super(lzo, batch_size);
    }


    /***************************************************************************

        Checks whether the specified value would fit in the currently available
        free space in the batch.

        Params:
            value = value to check

        Returns:
            true if the value would fit in the current free space, false if it's
            too big

    ***************************************************************************/

    public bool fits ( cstring value )
    {
        bool will_never_fit;
        return this.fits(value, will_never_fit);
    }


    /***************************************************************************

        Checks whether the specified value would fit in the currently available
        free space in the batch. Also returns, via an out parameter, whether it
        is impossible for the value to fit in the batch, even when it's empty.

        Params:
            value = value to check
            will_never_fit = output value, set to true if the value is larger
                than the batch buffer's dimension (meaning that the value can
                never fit in the batch, even when it's empty)

        Returns:
            true if the value would fit in the current free space, false if it's
            too big

    ***************************************************************************/

    public bool fits ( cstring value, out bool will_never_fit )
    out ( f )
    {
        if ( will_never_fit )
        {
            assert(!f);
        }
    }
    body
    {
        auto size = this.batchedSize(value);
        return this.fits(size, will_never_fit);
    }


    /***************************************************************************

        Checks whether the specified key/value would fit in the currently
        available free space in the batch.

        Params:
            key = key to check
            value = value to check

        Returns:
            true if the key/value would fit in the current free space, false if
            they're too big

    ***************************************************************************/

    public bool fits ( cstring key, cstring value )
    {
        bool will_never_fit;
        return this.fits(key, value, will_never_fit);
    }


    /***************************************************************************

        Checks whether the specified key/value would fit in the currently
        available free space in the batch. Also returns, via an out parameter,
        whether it is impossible for the key/value to fit in the batch, even
        when it's empty.

        Params:
            key = key to check
            value = value to check
            will_never_fit = output value, set to true if the key/value are
                larger than the batch buffer's dimension (meaning that the
                key/value can never fit in the batch, even when it's empty)

        Returns:
            true if the key/value would fit in the current free space, false if
            they're too big

    ***************************************************************************/

    public bool fits ( cstring key, cstring value, out bool will_never_fit )
    out ( f )
    {
        if ( will_never_fit )
        {
            assert(!f);
        }
    }
    body
    {
        auto size = this.batchedSize(key, value);
        return this.fits(size, will_never_fit);
    }


    /***************************************************************************

        Adds a value to the batch.

        Params:
            value = value to add

        Returns:
            code indicating result of add

    ***************************************************************************/

    public AddResult add ( cstring value )
    {
        bool will_never_fit;
        if ( !this.fits(value, will_never_fit) )
        {
            return will_never_fit ? AddResult.TooBig : AddResult.BatchFull;
        }

        size_t value_len = value.length;
        Const!(ubyte[]) value_len_str = (cast(ubyte*)&value_len)[0..size_t.sizeof];

        this.batch.append(value_len_str, cast(Const!(ubyte[]))value);

        return AddResult.Added;
    }


    /***************************************************************************

        Adds a key/value pair to the batch.

        Params:
            key = key to add
            value = value to add

        Returns:
            code indicating result of add

    ***************************************************************************/

    public AddResult add ( cstring key, cstring value )
    {
        bool will_never_fit;
        if ( !this.fits(key, value, will_never_fit) )
        {
            return will_never_fit ? AddResult.TooBig : AddResult.BatchFull;
        }

        size_t key_len = key.length;
        Const!(ubyte[]) key_len_str = (cast(ubyte*)&key_len)[0..size_t.sizeof];

        size_t value_len = value.length;
        Const!(ubyte[]) value_len_str = (cast(ubyte*)&value_len)[0..size_t.sizeof];

        this.batch.append(key_len_str, cast(Const!(ubyte[]))key, value_len_str,
            cast(Const!(ubyte[]))value);

        return AddResult.Added;
    }


    /***************************************************************************

        Compresses the batch into the provided buffer. The first size_t.sizeof
        bytes of the destination buffer contain the uncompressed length of the
        batch, which is needed for decompression.

        Once the batch has been compressed into the provided buffer, the batch
        is cleared, to be ready for re-use.

        Params:
            compress_buf = buffer to receive compressed data

        Returns:
            compress_buf, containing the compressed data

    ***************************************************************************/

    public ubyte[] compress ( ref ubyte[] compress_buf )
    {
        // Set destination to max possible length.
        compress_buf.length =
            this.lzo.maxCompressedLength(this.batch.length) + size_t.sizeof;
        enableStomping(compress_buf);

        // Write uncompressed length into first size_t.sizeof bytes of dest.
        *(cast(size_t*)(compress_buf.ptr)) = this.batch.length;

        // Compress into destination.
        auto dst = compress_buf[size_t.sizeof .. $];
        auto compressed_len = this.lzo.compress(this.batch[], dst);

        // Clear batch, ready for re-use
        this.clear();

        // Minimize dest length and return.
        compress_buf.length = compressed_len + size_t.sizeof;
        enableStomping(compress_buf);
        return compress_buf;
    }


    /***************************************************************************

        Calculates the size which a value will take up in a batch buffer.

        Params:
            value = value to calculate size of

        Returns:
            size value will take up in a batch buffer

    ***************************************************************************/

    private size_t batchedSize ( cstring value )
    {
        return size_t.sizeof + value.length;
    }


    /***************************************************************************

        Calculates the size which a pair of values will take up in a batch
        buffer.

        Params:
            value1 = first value to calculate size of
            value2 = second value to calculate size of

        Returns:
            size values will take up in a batch buffer

    ***************************************************************************/

    private size_t batchedSize ( cstring value1, cstring value2 )
    {
        return this.batchedSize(value1) + this.batchedSize(value2);
    }


    /***************************************************************************

        Checks whether the specified number of bytes would fit in the currently
        available free space in the batch. Also returns, via an out parameter,
        whether it is impossible for the extra bytes to fit in the batch, even
        when it's empty.

        Params:
            extra_bytes = number of extra bytes to check
            will_never_fit = output value, set to true if the extra bytes are
                larger than the batch buffer's dimension (meaning that the
                extra bytes can never fit in the batch, even when it's empty)

        Returns:
            true if the extra bytes would fit in the current free space, false
            if they're too big

    ***************************************************************************/

    private bool fits ( size_t extra_bytes, out bool will_never_fit )
    out ( f )
    {
        if ( will_never_fit )
        {
            assert(!f);
        }
    }
    body
    {
        if ( extra_bytes > this.batch.dimension )
        {
            will_never_fit = true;
            return false;
        }
        else
        {
            return this.batch.length + extra_bytes <= this.batch.dimension;
        }
    }
}



/*******************************************************************************

    Class to decompress and extract records from batches.

    A compressed batch should be passed to the decompress() method. Following
    decompression, the extract() method may be called to extract the values
    contained in the batch.

*******************************************************************************/

public class RecordBatch : RecordBatchBase
{
    /***************************************************************************

        Constructor.

        Params:
            lzo = lzo de/compressor to use
            batch_size = batch size to use

    ***************************************************************************/

    public this ( Lzo lzo, size_t batch_size = DefaultMaxBatchSize )
    {
        super(lzo, batch_size);
    }


    /***************************************************************************

        Decompresses the provided compressed data into this batch. The data
        buffer is assumed to have been written by RecordBatcher.compress().

        Following decompression, either of the extract() methods can be used to
        retrieve the individual records stored in the batch.

        Params:
            compressed = buffer containing compressed data

    ***************************************************************************/

    public void decompress ( in ubyte[] compressed )
    {
        // Read uncompressed length from first size_t.sizeof bytes.
        auto uncompressed_len = *(cast(size_t*)(compressed.ptr));
        assert(uncompressed_len <= this.batch.dimension);
        this.batch.length = uncompressed_len;

        // Decompress into this.batch.
        auto src = compressed[size_t.sizeof .. $];
        this.lzo.uncompress(src, this.batch[]);
    }


    /***************************************************************************

        foreach iteration. Extracts values from the batch, calling the provided
        delegate once per value.

        Params:
            record_dg = delegate to call for each extracted value

    ***************************************************************************/

    public int opApply ( int delegate ( ref cstring value ) record_dg )
    {
        int r;
        size_t consumed;

        while ( consumed < this.batch.length )
        {
            auto value = this.extractValue(consumed);
            r = record_dg(value);
            if ( r ) break;
        }

        return r;
    }


    /***************************************************************************

        foreach iteration. Extracts all paired values from the batch, calling
        the provided delegate once per pair.

        Params:
            record_dg = delegate to call for each extracted value pair

    ***************************************************************************/

    public int opApply (
        int delegate ( ref cstring value1, ref cstring value2 ) record_dg )
    {
        int r;
        size_t consumed;

        while ( consumed < this.batch.length )
        {
            auto value1 = this.extractValue(consumed);
            auto value2 = this.extractValue(consumed);
            r = record_dg(value1, value2);
            if ( r ) break;
        }

        return r;
    }


    /***************************************************************************

        Extracts a single value from the batch.

        Params:
            consumed = progress through the batch buffer, updated as a value is
                extracted

        Returns:
            slice to extracted value

    ***************************************************************************/

    private cstring extractValue ( ref size_t consumed )
    {
        size_t len = *(cast(size_t*)(this.batch.ptr + consumed));
        consumed += size_t.sizeof;

        auto value = cast(mstring) this.batch[consumed .. consumed + len];
        consumed += len;

        return value;
    }
}
