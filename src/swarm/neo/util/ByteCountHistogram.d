/*******************************************************************************

    A byte throughput statistics counter for any sort of transaction that
    usually processes up to a few kB at once. Collects the following statistical
    information:
    - a logarithmic byte throughput histogram with bins from ≥1B to <64kiB, one
      bin per power of two, plus one bin for each 0B and ≥64kiB,
    - the total number of transactions and the aggregated total amount of bytes.

    To reset all counters to zero use `ByteCountHistogram.init`.

    copyright: Copyright (c) 2017 sociomantic labs GmbH. All rights reserved.

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.neo.util.ByteCountHistogram;

import ocean.transition;

/// ditto
struct ByteCountHistogram
{
    import core.bitop: bsr;
    import ocean.core.Traits : FieldName;

    /***************************************************************************

        The total aggregated number of bytes processed by all transactions.

    ***************************************************************************/

    ulong total;

    /***************************************************************************

        The total number of transactions.

    ***************************************************************************/

    uint count;

    /***************************************************************************

        The bins of the byte count histogram. Given a number of bytes processed
        by a transacion the index i of the bin to increment is calculated as
        follows:

        - If 1 ≤ n and n < 2^16 (= 64ki): i = floor(log_2(n)) + 1,
        - otherwise, if t < 1: i = 0,
        - otherwise, i.e. t ≥ 2^16: i = 17.

        0: 0,
        1:       1, 2:  2 -   3, 3:   4 -   7, 4:   8 -  15,  5:  16 -   31,
        6: 32 - 63, 7: 64 - 127, 8: 128 - 255, 9: 256 - 511, 10: 512 - 1023,
        11: 1ki -  (2ki-1), 12:  2ki -  (4ki-1), 13:  4ki -  (8ki-1),
        14: 8ki - (16ki-1), 15: 16ki - (32ki-1), 16: 32ki - (64ki-1),
        17: 64ki - ∞

    ***************************************************************************/

    uint[18] bins;

    /***************************************************************************

        Struct with one uint field per bin (see this.bins), named as follows:
            from_0b ("from 0 bytes"), from_1b, from_2b, from_4b, from_8b,
            from_16b, ...,
            from_1Kib, from_2Kib, ...,
            from_64Kib ("from 64Kib")

        Useful, for example, for logging the whole histogram.

    ***************************************************************************/

    public struct Bins
    {
        import ocean.core.Traits : ctfe_i2a;

        /***********************************************************************

            Interprets the passed bins array as a Bins instance.

            Params:
                array = bins array to reinterpret

            Returns:
                the passed bins array as a Bins instance

        ***********************************************************************/

        public static Bins fromArray ( typeof(ByteCountHistogram.bins) array )
        {
            return *(cast(Bins*)array.ptr);
        }

        /***********************************************************************

            Sanity check that the offset of the fields of this struct match the
            offsets of the elements of a ByteCountHistogram.bins array. (i.e.
            that the fromArray() function can work as intended.)

        ***********************************************************************/

        static assert(fieldOffsetsCorrect());

        /***********************************************************************

            Returns:
                true if the offset of the fields of this struct match the
                offsets of the elements of a ByteCountHistogram.bins array

        ***********************************************************************/

        private static bool fieldOffsetsCorrect ( )
        {
            foreach ( i, field; typeof(Bins.tupleof) )
                if ( Bins.tupleof[i].offsetof != i * ByteCountHistogram.init.bins[i].sizeof )
                    return false;
            return true;
        }

        /***********************************************************************

            CTFE generator of the fields of this struct.

            Params:
                max_power = maximum power of 2 contained within a bin

            Returns:
                code for the series of fields for bins up to the specified
                maximum power of 2. (See unittest for examples.)

        ***********************************************************************/

        private static istring divisionBinVariables ( uint max_power )
        {
            const type = typeof(ByteCountHistogram.bins[0]).stringof;

            istring res;

            istring formatBytes ( ulong bytes )
            {
                // Only supports formatting metric prefixes up to Kib. Could be
                // extended, if needed in the future.
                if ( bytes < 1024 )
                    return ctfe_i2a(bytes) ~ "b";
                else
                    return ctfe_i2a(bytes / 1024) ~ "Kib";
            }

            res ~= type ~ " from_" ~ formatBytes(0) ~ ";";

            for ( size_t power = 0; power <= max_power; power++ )
                res ~= type ~ " from_" ~ formatBytes(1 << power) ~ ";";

            return res;
        }

        unittest
        {
            test!("==")(divisionBinVariables(0), "uint from_0b;uint from_1b;");
            test!("==")(divisionBinVariables(ByteCountHistogram.bins.length - 2),
                "uint from_0b;uint from_1b;uint from_2b;uint from_4b;uint from_8b;uint from_16b;uint from_32b;uint from_64b;uint from_128b;uint from_256b;uint from_512b;uint from_1Kib;uint from_2Kib;uint from_4Kib;uint from_8Kib;uint from_16Kib;uint from_32Kib;uint from_64Kib;");
        }

        /***********************************************************************

            Fields.

        ***********************************************************************/

        mixin(divisionBinVariables(ByteCountHistogram.bins.length - 2));
    }

    /***************************************************************************

        The number of fields of Bins must equal the length of the fixed-length
        array this.bins.

    ***************************************************************************/

    static assert(Bins.tupleof.length == bins.length);

    /***************************************************************************

        Counts a transaction that processed `n` bytes by incrementing the
        corresponding histogram bin and the total number of transactions and
        adding `n` to the total number of bytes.

        Params:
            n = the number of bytes processed by the transaction

        Returns:
            n

    ***************************************************************************/

    ulong countBytes ( ulong n )
    {
        this.count++;
        this.total += n;
        this.bins[n? (n < (1UL << 16))? bsr(n) + 1 : $ - 1 : 0]++;
        return n;
    }

    /***************************************************************************

        Returns:
            the mean amount of bytes processed by each transaction or NaN if
            this.count == 0.

    ***************************************************************************/

    public double mean_bytes ( )
    in
    {
        assert(this.count || !this.total);
    }
    body
    {
        return this.total / cast(double)this.count;
    }

    /***************************************************************************

        Gets the count of transactions in the specified bin.

        Params:
            bin_name = string name of the bin to get the count for. Must match
                the name of one of the fields of Bins

        Returns:
            the number of transactions in the specified bin

    ***************************************************************************/

    public ulong countFor ( istring bin_name ) ( )
    {
        mixin("static assert(is(typeof(Bins.init." ~ bin_name ~ ")));");

        mixin("const offset = Bins.init." ~ bin_name ~ ".offsetof;");
        const index = offset / this.bins[0].sizeof;
        return this.bins[index];
    }

    unittest
    {
        ByteCountHistogram histogram;
        histogram.countBytes(7);
        test!("==")(histogram.countFor!("from_4b")(), 1);
    }

    /***************************************************************************

        Returns:
            the complete histogram as a Bins struct

    ***************************************************************************/

    public Bins stats ( )
    {
        return Bins.fromArray(this.bins);
    }

    unittest
    {
        ByteCountHistogram histogram;
        histogram.countBytes(7);
        auto bins = histogram.stats();
        test!("==")(bins.from_4b, 1);
    }
}

version (UnitTest)
{
    import ocean.core.Test;
}

unittest
{
    ByteCountHistogram bch;

    // Tests if bch.count is `expected` and matches the sum of all bin
    // counters.
    void checkBinSum ( uint expected, istring f = __FILE__, int ln = __LINE__ )
    {
        test!("==")(bch.count, expected, f, ln);
        uint sum = 0;
        foreach (bin; bch.bins)
            sum += bin;
        test!("==")(sum, bch.count, f, ln);
    }

    // 0 Bytes: Should increment bins[0] and `count` to 1 and leave
    // `total == 0`. All other bins should remain 0.
    bch.countBytes(0);
    test!("==")(bch.total, 0);
    checkBinSum(1);
    test!("==")(bch.bins[0], 1);
    test!("==")(bch.stats.from_0b, 1);
    test!("==")(bch.countFor!("from_0b"), 1);
    foreach (bin; bch.bins[1 .. $])
        test!("==")(bin, 0);

    // 1500 Bytes: Should increment bins[11] to 1, `count` to 2 and `total` to
    // 1500. bins[0] should stay at 1. All other bins should remain 0.
    bch.countBytes(1500);
    test!("==")(bch.total, 1500);
    checkBinSum(2);
    test!("==")(bch.bins[0], 1);
    test!("==")(bch.stats.from_0b, 1);
    test!("==")(bch.countFor!("from_0b"), 1);
    test!("==")(bch.bins[11], 1);
    test!("==")(bch.stats.from_1Kib, 1);
    test!("==")(bch.countFor!("from_1Kib"), 1);
    foreach (i, bin; bch.bins)
    {
        switch (i)
        {
            default:
                test!("==")(bch.bins[i], 0);
                goto case;
            case 0, 11:
        }
    }

    // 1,234,567,890 (more than 65,535) Bytes: Should increment bins[$ - 1]
    // to 1, `count` to 3 and `total` to 1500 + 1,234,567,890. bins[0] and
    // bins[11] should stay at 1. All other bins should remain 0.
    bch.countBytes(1_234_567_890);
    test!("==")(bch.total, 1_234_567_890 + 1500);
    checkBinSum(3);
    test!("==")(bch.bins[0], 1);
    test!("==")(bch.stats.from_0b, 1);
    test!("==")(bch.countFor!("from_0b"), 1);
    test!("==")(bch.bins[11], 1);
    test!("==")(bch.stats.from_1Kib, 1);
    test!("==")(bch.countFor!("from_1Kib"), 1);
    test!("==")(bch.bins[$ - 1], 1);
    test!("==")(bch.stats.from_64Kib, 1);
    test!("==")(bch.countFor!("from_64Kib"), 1);
    foreach (i, bin; bch.bins)
    {
        switch (i)
        {
            default:
                test!("==")(bch.bins[i], 0);
                goto case;
            case 0, 11, bch.bins.length - 1:
        }
    }
}
