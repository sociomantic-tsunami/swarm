.. contents ::

Core Concepts
================================================================================

The ``swarm.neo.client`` package provides the foundations for clients which
perform asynchronous communication with a service distributed across a set of
one or more "nodes" (each node being an individual process).

The client opens a single TCP connection to each node and multiplexes requests
over this connection. This, combined with the distribution of the server across
multiple nodes, leads to the possibility of many requests being executed in
parallel (asynchronously -- the asynchronous performance of requests is handled
by epoll).

Authentication
--------------------------------------------------------------------------------

When a socket connection is established, the node initiates an authentication
process. The client thus requires a name and key which are validated by the node
by an HMAC-based authentication process. The authentication name and key are
specified via the client's constructor. (In fact, it is the calling of this new
constructor, providing the neo authentication information, that enables the neo
functionality of a client.)

Key Generation
--------------------------------------------------------------------------------

The key used for authentication should be a crypotgraphic random number which
only the client and the nodes know. It must be of the length defined in
``swarm.neo.authentication.HmacDef`` (128 bytes). It is suggested that a
256-character hex string key be generated using `openssl rand -hex 128` and
stored in the application's and nodes' config files. The key can then be read in
and converted to a 128-byte ``ubyte[]`` using ``ocean.text.convert.Hex :
hexToBin``.

Channels
--------------------------------------------------------------------------------

Some types of node contain multiple 'channels' -- completely separate, named
sets of data which can be accessed independently. For this type of node, a
channel name must be specified for almost all client requests.

Channels are named with a string, which can only contain alphanumeric (ASCII
0x41..0x5A, 0x61..0x7A and 0x30..0x39), underscore (ASCII 0x5F) and dash (ASCII
0x2D) characters.

Client Internals
================================================================================

The Neo Object
--------------------------------------------------------------------------------

All "neo" functionality is wrapped inside a public member of the client class,
named ``neo``.

The Connection Set
--------------------------------------------------------------------------------

The client maintains a set of connections, one per node which makes up the
service. These can be added individually via the ``neo.addNode()`` method, or
read from a text file provided to the ``neo.addNodes()`` method. It is not
possible to use a client without first adding at least one node.

Connections
--------------------------------------------------------------------------------

When a connection is added to the connection set (via one of the methods
mentioned above), the client automatically attempts to establish the connection
and will retry until successful. (This behaviour also kicks in if the connection
is broken, for any reason.) The user is notified, via a callback, when the
connection is established.

The Request Set
--------------------------------------------------------------------------------

The client contains method to assign requests. When this happens, a new request
is added to the internal request set. When a request is finished, it is removed
from the request set. The request set has a maximum size (this is currently
defined as 5,000). If a request is assigned when the set is already at its
maximum size, the assignment will fail and an exception of type
``swarm.neo.client.RequestSet : RequestSet.NoMoreRequests`` will be thrown.

Requests
--------------------------------------------------------------------------------

Each request in the request set is given a uniquely identifying id (a 64-bit
integer of type ``swarm.neo.protocol.Message: RequestId``) which is
returned by the assigning method. When the client and node communicate with each
other, the request id is passed as part of each message, so that the request
responsible for each message multiplexed over the connection can be identified.

Requests are of three types:

1. **Single-node:** A request which accesses one node at a time -- usually only
   a single node over its whole lifetime. The node(s) accessed are determined
   entirely by the request itself.
2. **Round-robin:** A request which accesses on node at a time, balancing load
   over the set of all connections in a round-robin fashion. A request of this
   type which experiences an error will typically automatically retry on the
   next connection in the set.
3. **All-nodes:** A request which communicates with all nodes simultaneously.
   Typically, when a connection breaks down, a request of this type will
   automatically re-establish communication with the node and restart the
   request on that node.

Basic Client Usage
================================================================================

When a request is assigned, the following process takes place:

1. As mentioned above, the new request is added to the request set and assigned
   a unique id. All user-specified arguments to the request (e.g. channel names,
   keys, values, etc) are copied internally in the client -- the user does not
   need to maintain any buffers.
2. Depending on the type of request (see above), the request begins
   communicating with one or more nodes. A request begins by sending messages
   describing itself (e.g. its request code, the name of the channel to be
   accessed, and so on) to the node(s) over the connections in the connection
   set.
3. When socket communication is initiated, it typically will not complete
   immediately (although it is possible) and the client will register the
   connection with epoll, to receive a notification when the socket is ready for
   communication. Thus the application using the client must activate the epoll
   event loop to perform the assigned requests.

Request API Modules
--------------------------------------------------------------------------------

Every request has a module which defines its public API. These are located in
the ``client.neo.request`` package of the client. These modules are publicly
imported by the client's neo object, for convenient access by the user. You can
thus access them like: ``Client.Neo.NameOfRequest``.

Request API modules typically contain:

* A type alias for the notification delegate.
* The definition of the smart-union and arguments struct which are passed to the
  notification delegate.
* The request's controller interface, if applicable (see below).

Error Handling and Request Notification
--------------------------------------------------------------------------------

All exceptions which occur in the client or inside the epoll event loop are
caught and handled internally, so as not to interrupt the asynchronous handling
of multiple requests. All request methods thus require a notification delegate
to be provided, in order to inform the application of errors which occurr while
handling the request.

The notification delegate is also used to notify the application of various
other state changes while handling a request. Requests which read data from the
remote service also call the notification delegate to provide the resulting data
to the user.

The exact situations which invoke the notification delegate vary depending on
the request, but they all take the following form: ``void delegate ( N, A )``,
where ``N`` is a smart-union (see ``ocean.core.SmartUnion``) of notifications
specific to the request and ``A`` is a struct containing the arguments which
were specified by the user when the request was assigned. A typical notification
delegate looks something like this imaginary example:

.. code-block:: D

  void notifier ( NotificationUnion info, RequestArgs args )
  {
    // As info is a smart-union, we can tell which member is active.
    with ( info.Active ) switch ( info.active ) 
    {
      case success: // example success notification
        Stdout.formatln("Request on channel {} succeeded and returned the "
            "value {}", args.channel, info.value);
        break;

      case error: // example I/O error notification
        Stderr.formatln("Request on channel {} failed due to error {} "
            "on {}:{}", args.channel, getMsg(info.e),
            cast(char[])info.node_addr.address_bytes, info.node_addr.port);
        break;

      default: assert(false); // Or use final switch, in D2
    }
  }

Advanced Client Features
================================================================================

Request Controllers
--------------------------------------------------------------------------------

Some requests which are active for an extended period (for example requests
which read a large volume of data from the remote service or which consume a
persistent stream of data from the service) provide a "controller" API which
enables the user to alter the execution of the request, while it is in progress.

To control a request, use the ``neo.control()`` method of the client and pass
the id of the request that you wish to control. If the request is still active,
you will be provided with a controller interface appropriate to your request.
The methods provided by this interface depend entirely on the type of the
request. The request controller may, for example, provide methods to suspend,
resume, or stop the request.

Suspendable Requests
--------------------------------------------------------------------------------

The client provides an alternative request control API where an object is
associated with a request id (specified in its constructor) and used to control
the request. When the request finishes, the object becomes invalid and all its
methods will throw. This kind of control API may be accessed via the
``Controller`` class template defined in the client.

Furthermore, requests whose controllers implement ``suspend()`` and ``resume()``
methods may be used with the ``Suspendable`` class template defined in the
client. Classes instantiated by this template implement ocean's ``ISuspendable``
and are thus compatible with the throttler classes in ocean, with the following
caveat:

* While it implements the standard ``ISuspendable``, the ``Suspendable`` class
  is only a partial match for that interface. The difference lies in the fact
  that suspendable requests only allow a single state-change (i.e. suspend or
  resume) signal to be in flight to the node at any one time. Because of this --
  and at odds with what ``ISuspendable`` normally expects -- a call to
  ``suspend()`` or ``resume()`` may not immediately take effect. Instead, the
  ``Suspendable`` notes that a state-change was requested and carries it out
  when the ``handlePending()`` method is called by the user. Thus,
  ``handlePending()`` should be called when the user is notified that the
  previous state-change has been completed.

Build Flags
================================================================================

* **debug=SwarmConn**: console output of information on client/node
  authentication and connection establishment.
* **debug=SwarmClient**: console output of information on request handling.
