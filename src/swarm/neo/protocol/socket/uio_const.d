/*******************************************************************************

    D-`const`-correct vector/gather socket output with optional `SIGPIPE`
    suppression.

    Copyright: Copyright (c) 2015-2017 dunnhumby Germany GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module swarm.neo.protocol.socket.uio_const;

import core.sys.posix.sys.types: ssize_t;

import core.sys.posix.sys.socket;

import ocean.transition;

/*******************************************************************************

    D-`const`-correct output version of `iovec`. It is used like `iovec` for
    functions that only read the data referenced by `iov_base`, i.e. output
    functions. It fixes the following problem:

    ```
        int socket_fd;

        // Define some read-only data to pass to sendv.
        auto a = "Hello", b = "World";

        // Declare an output vector
        iovec[2] output_vec;

        // Set the output vector components to reference the read-only data.
        output_vec[0].iov_base = a.ptr;     // Problem
        output_vec[0].iov_len  = a.length;
        output_vec[1].iov_base = b.ptr;     // Problem
        output_vec[1].iov_len  = b.length;

        // Send the output data i.e. a ~ b through the socket.
        auto bytes_sent = sendv(socket_fd, output_vec);
    ```

    The problem here is that the type of `iovec.iov_base` is (mutable) `void*`
    but we need it to reference read-only string data of type `immutable(char)`.
    This is illegal. We need `iovec.iov_base` to be of type `const(void)*`.

    Seemingly, a solution would be to declare `const(iovec)[2] output_vec`. But
    that would cause another problem: `sendv` may only send a part of the output
    data, in which case `bytes_sent` would be less than
    `output_vec[0].iov_len + output_vec[1].iov_len`, and we need to adjust the
    elements of `output_vec` to reference the remaining data and pass them to
    another `sendv` call, and we need to do this in a loop until `sendv` has
    sent all data referenced by `output_vec`. If the elements of `output_vec`
    are now of type `const(iovec)` then we cannot modify them in-place but would
    have to create copies on every cycle of the loop. Although this would be
    possible it would cause unnecessary memory allocations in a potentially
    performance critical code location.

    So there is a need for `iovec_const`, an `iovec` equivalent with `iov_base`
    of type `const(void)*`.

    A little more background information: `iovec` is part of the `uio` POSIX API
    for I/O functions performing so-called "vector I/O" or "scatter input
    gather output". Expressed in D, they accept a `void[][]` array, called
    "vector", of I/O data buffers (rather than one `void[]` I/O data buffer like
    ordinary I/O functions) and write input data to or read output data from
    these buffers, resp., in the order of appearance.

    http://pubs.opengroup.org/onlinepubs/9699919799/basedefs/sys_uio.h.html

    The most primitive functions of this family are
    ```
        ssize_t readv(int fd, in iovec* iov, int iovcnt);
        ssize_t preadv(int fd, in iovec* iov, int iovcnt, off_t offset);
        ssize_t writev(int fd, in iovec* iov, int iovcnt);
        ssize_t pwritev(int fd, in iovec* iov, int iovcnt, off_t offset);
    ```
    These functions accept an `iovec[] data` array in the way that
    `iov = data.ptr` and `iovcnt = data.length`.
    More advanced functions include
    ```
         ssize_t recvmsg(int sockfd, scope msghdr* msg, int flags);
         ssize_t sendmsg(int sockfd, in msghdr* msg, int flags);
    ```
    where `msghdr` is a struct containing the fields
    ```
        iovec* msg_iovec;
        size_t msg_iovlen;
    ```
    which is again an `iovec[]` array with `msg_iovec = ptr` and
    `msg_iovlen = length`. The `sendv` function in this module is a wrapper for
    `sendmsg`.

    All functions in this API have in common that they use the same `iovec`
    array pointer type for both input and output functions where the input
    functions do write-only access to the data referenced by the `iov_base`
    fields of the `iovec` struct instances involved and the output functions
    read-only. None of the output functions is `const`-correct, all of them
    should use alternative struct definitions with `const(void)*` pointers
    referencing the output data.

    Unfortunately this API was not designed with `const` in mind.

*******************************************************************************/

struct iovec_const
{
    const(void)* iov_base;
    size_t iov_len;
}

/*******************************************************************************

    This is a `const`-correct hybrid of `send(2)` and `writev(2)`:
    - Like `send` it works only with a connection-mode socket and accepts the
      same flags as `send`.
    - Like `writev` it performs gather-output, accepting a vector (i.e. array)
      of output buffers, which is, in contrast to `writev(2)`,
      D-`const`-correct.

    Params:
        socket_fd = the socket file descriptor
        data      = the output data, see the `writev(2)` docu for details
        flags     = `MSG_*` flags; see `send(2)` documentation

    Returns:
        0 on success or -1 on failure, in which case `errno` is set accordingly.

*******************************************************************************/

ssize_t sendv ( int socket_fd, in iovec_const[] data, int flags = 0 )
{
    const(msghdr) m = {
            msg_iov:    cast(const(iovec*))data.ptr,
            msg_iovlen: data.length
    };
    return sendmsg(socket_fd, &m, flags);
}

// Ensure binary compatibility of `iovec_const` with `iovec`.
unittest
{
    static assert(iovec_const.sizeof == iovec.sizeof);
    static assert(iovec_const.alignof == iovec.alignof);

    alias typeof(iovec.tupleof)       iovecFields;
    alias typeof(iovec_const.tupleof) iovec_constFields;
    static assert(iovec_constFields.length == iovecFields.length);

    foreach (i, iovec_constField; iovec_constFields)
    {
        static if (is(iovec_constField == const(void)*))
            static assert(is(iovecFields[i] == void*));
        else
            static assert(is(iovec_constField == iovecFields[i]));

        static assert(iovec_const.tupleof[i].offsetof ==
                      iovec.tupleof[i].offsetof);
        static assert(iovec_const.tupleof[i].alignof ==
                      iovec.tupleof[i].alignof);
    }
}
