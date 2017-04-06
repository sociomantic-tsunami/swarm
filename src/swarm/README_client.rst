.. contents ::

Core Concepts
================================================================================

The core swarm client (``swarm.client.model.IClient``) provides an abstract
base for clients which perform asynchronous communication with a service
distributed across a set of one or more "nodes" (each node being an individual
process).

The client can operate using multiple connections to each node. This, combined
with the distribution of the server across multiple nodes, leads to the
possibility of many requests being executed in parallel (asynchronously -- the
asynchronous performance of requests is handled by epoll).

Channels
--------------------------------------------------------------------------------

Some types of node contain multiple 'channels' -- completely separate, named
sets of data which can be accessed independently. For this type of node, a
channel name must be specified for almost all client requests.

Channels are named with a string, which can only contain alphanumeric (ASCII
0x41..0x5A, 0x61..0x7A and 0x30..0x39), underscore (ASCII 0x5F) and dash (ASCII
0x2D) characters.

In addition to the restrictions on valid channel names, it is important to note
that all requests which require a channel name store a slice to the channel name
internally -- they are not copied. This is deliberate, as channel names are
almost always constant. In the rare situation where this is not the case, then
the application must deal with making sure the channel names are maintained
safely so that they can be safely sliced.

The Node Registry
--------------------------------------------------------------------------------

The ``IClient`` maintains a "registry" of the nodes which make up the service.
These can be added individually via the ``addNode()`` method, or read from a
text file provided to the ``addNodes()`` method. It is not possible to use a
client without adding at least one node.

A variety of information can be queried from the node registry via the ``nodes``
property of ``IClient`` (see `The Node Registry Information Interface`_).

The Node Connection Pools
--------------------------------------------------------------------------------

For each node in the client's registry, a pool of socket connections is
maintained. The pool is initially empty, but connections will be added to it
when requests are assigned to the client (see `Basic Client Usage`_). Each
connection performs a single request before becoming idle again. Idle
connections are reused to perform further requests in the future.

Each node connection pool has a maximum size, denoting the maximum number of
requests which can be performed in parallel to the node. When the pool reaches
its maximum size and all connections in the pool are busy, no more connections
will be established and any incoming requests will be queued for future
execution when a connection becomes idle (see `Basic Client Usage`_).

A variety of information can be queried from the node connection pools via the
``opApply`` iterator of the ``nodes`` property of ``IClient`` (see `The Node
Connection Pool Information Interface`_).

Basic Client Usage
================================================================================

Non-abstract client classes which are derived from ``IClient`` will provide a
set of request methods, each of which returns a struct which can be passed to
the client's ``assign()`` method. When a request is assigned, the following
process takes place:

1. The client determines which node the request should be sent to. This logic
   varies depending on the type of the client. Some requests may also be sent to
   multiple nodes in parallel.
2. The client checks to see whether an idle connection exists to the selected
   node(s), and sends the request to it immediately, if found.
3. If an idle connection is not found, but the maximum number of connections per
   node has not been reached, then a new connection to the selected node is
   opened and the request is sent.
4. If no idle connection exists and the pool of connections to the selected
   node is at its maximum size, the request is placed in the request queue for
   the selected node, and will be executed when a connection becomes idle.

When a request is executed, it initiates communication with the socket
connection to the node. This typically will not complete immediately (although
it is possible), and the client will register the request/connection with epoll,
to receive a notification when the socket is ready for communication. Thus the
application using the client must activate the epoll event loop to perform the
assigned requests.

In general, as many requests as possible (depending on the number of nodes &
connections per node) are active simultaneously, enabling a large number of
requests to be executed in parallel (asynchronously) -- the available bandwidth
can thus be used very effectively.

Error Handling and Request Notification
--------------------------------------------------------------------------------

All exceptions which occur in the client or inside the epoll event loop are
caught and handled internally, so as not to interrupt the asynchronous handling
of multiple requests. All request methods thus require a notification delegate
to be provided, in order to inform the application of errors which occurred
while handling a request.

The notification delegate is also used to notify the application of various
other state changes while handling a request.

The following situations invoke the notification delegate:

1. When a request is scheduled for future handling (see `Scheduler`_).
2. When a request is pushed to an internal request queue for future handling.
3. When handling of a request begins.
4. When handling of a request finishes (including due to an error).

The notifier callback receives an object of the type ``RequestNotification``,
which has the following members of interest:

* ``type`` = indicates the type of the notification (the 4 cases above).
* ``status`` = the status code received from the node. In the case of a
  successfully completed request, this will always be Ok (200). In the case of
  an error occurring in the node while handling the request, the status will be
  non-ok. In the case where an error occurred in the client while handling the
  request, before the request was sent to the node, the status code will be
  Undefined (0).
* ``exception`` = a reference to an ``Exception`` instance indicating an error
  which occurred in the client.
* ``succeeded`` = a boolean value telling whether the request succeeded (only
  valid if ``type == Finished``).

Note: in the rare case of an application which really doesn't care about any
errors which may occur when handling requests (this is usually only true for
quickly hacked, one-off programs), it is quite alright to pass a null
notification delegate. In this case no notification of any kind will occur for
the request.

User Data Delegates
--------------------------------------------------------------------------------

All requests send or receive any required data via a user-provided delegate,
which is called at the point when the request is executed. For requests which
receive data from the server, the delegate is called when the data has been
received, passing the received data to the client application. For requests
which send data to the server, the delegate is called when the client is ready
to send, requesting the data to be sent from the client application. This means
that the data to be sent must be stored by the application until the finished
notification for the request is received.

Information Interfaces
================================================================================

The Node Registry Information Interface
--------------------------------------------------------------------------------

The core ``IClient`` class provides a property called ``nodes``, an interface of
type ``INodeRegistryInfo``, with methods to get information about the set of
nodes which are registered with the client (i.e. the set of nodes which the
client knows about and can communicate with). For example:

* The ``length()`` method of ``INodeRegistryInfo`` returns the number of nodes
  in the registry.
* The ``queued_requests()`` method returns the number of requests which are
  queued and waiting for execution (summed across all nodes in the registry --
  which each has its own request queue).
* The ``opApply`` method provides foreach iteration over the information
  interfaces of the individual nodes in the registry (see `The Node Connection
  Pool Information Interface`_).

Members of `INodeRegistryInfo`
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
.. code-block:: D

    class INodeRegistryInfo
    {
        size_t length ( ); // number of nodes
        size_t max_connections_per_node ( );
        size_t queue_limit ( ); // bytes
        size_t queued_requests ( );
        size_t overflowed_requests ( );
        int opApply ( int delegate ( ref INodeConnectionPoolInfo ) dg );
    }

The Node Connection Pool Information Interface
--------------------------------------------------------------------------------

Information about the individual nodes and the associated pool of connections in
a client's registry can be obtained by performing a foreach iteration over the
``INodeRegistryInfo`` interface returned by the ``nodes`` property of
``IClient``. For each node in the registry, the user foreach delegate receives
an interface of type ``INodeConnectionPoolInfo``. This interface provides a set
of methods to query information about the node and the pool of connections which
are communicating with it. For example:

* The ``address()`` and ``port()`` methods of ``INodeConnectionPoolInfo``
  return the ip address and port of the node.
* The ``queued_requests()`` method returns the number of requests which are
  queued and waiting for execution to the node.
* The ``error_count()``, ``io_timeout_count()`` and ``conn_timeout_count()``
  methods return the cumulative number of errors, I/O timeouts and connection
  timeouts which have occurred for requests to this node since counting begun or
  was reset. The error/timeout counters can be reset with the
  ``resetCounters()`` method.

Members of `INodeConnectionPoolInfo`
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
.. code-block:: D

    class INodeConnectionPoolInfo
    {
        char[] address ( );
        ushort port ( );
        uint length ( ); // connections
        uint num_idle ( );
        uint num_busy ( );
        size_t queued_requests ( );
        size_t queued_bytes ( );
        size_t overflowed_requests ( );
        ulong error_count ( );
        ulong io_timeout_count ( );
        ulong conn_timeout_count ( );
        void resetCounters ( );
    }

Advanced Client Features
================================================================================

Client Plugins
--------------------------------------------------------------------------------

A number of plugins exist for the clients (concrete clients may also have
additional plugins specific to their functioning), which expand their basic
functionality. Plugins may modify the internal behaviour of the client, and may
add one or more public methods to the client class, callable by the user. See
`Client Plugins`_.

Request Objects and Optional Settings
--------------------------------------------------------------------------------

The objects which are returned by the request commands are to be passed to
the ``assign()`` method for execution (or other execution methods provided by
plugins). The request objects also provide a number of methods which may
optionally be called before the request is assigned, allowing additional
(non-mandatory) parameters of the request to be specified. Each request method
lists these optional methods. The optional methods can all be called in a chain,
see example below.

Optional Request Parameters Example
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
.. code-block:: D

    // Get request assigned with only required settings.
    client.assign(client.get(channel, key, &getCallback, &notify));

    // Get request assigned with some additional optional settings.
    client.assign(client.get(channel, key, &getCallback, &notify).context(23)
      .timeout(42));

Request Timeouts
--------------------------------------------------------------------------------

Via the ``timeout()`` method of the request object, all requests may be assigned
with a timeout value set (in milliseconds). The timeout value is per-I/O
operation (i.e. per read or write to the socket), *not* per-request, but this
seldom makes any difference in practice. If an I/O operation for the request
exceeds the specified timeout value, the request is cancelled and the
notification callback is invoked (with type = finished and exception set to an
instance of ``TimedOutException``).

Note that the node which was handling the request may actually have completed
the request by the time it times out on the client's side.

Request Contexts
--------------------------------------------------------------------------------

When an I/O callback delegate is called, the client application needs to be able
to tell which request resulted in this call. Imagine the case where you are
executing multiple requests over different channels, which are in turn being
performed in parallel over multiple nodes -- the records read by these requests
could quite conceivably all be being passed to a single callback delegate! So
how does the delegate know how to interpret the data?

This is the situation where 'request contexts' are essential. Every request
object which has an I/O delegate has an optional parameter which can be used to
specify the context of the request. The context is an instance of the
``RequestContext`` struct (see ``swarm.client.request.context.RequestContext``),
which can contain the following forms of context:

1. a ``hash_t``
2. an ``Object`` reference
3. a pointer (``void*``)

Client Plugins
================================================================================

Scheduler
--------------------------------------------------------------------------------

This plugin adds a public method, ``schedule()``, to the client, which, as an
alternative to the simple assignment of requests for immediate execution (via
the ``assign()`` method), allows requests to be scheduled for future execution.
The delay before execution is specified by the user, in milliseconds.

Scheduling of requets is especially useful in situations where you wish to retry
a failed request. In this case, the failed request can usually be re-scheduled
directly in the notification callback which reported its failure.

Build Flags
================================================================================

* **debug=SwarmAuth**: console output of information on client/node
  authentication.
* **debug=SwarmClient**: console output of information on request handling.
