This README contains documentation aimed at developers who are using swarm to
develop protocols, clients, and nodes. As such, it discusses the internals of
the library, and is not relevant to _users_ of swarm-based clients. (Users
should refer to [`README_client.rst`](README_client.rst) and
[`README_client_neo.rst`](README_client_neo.rst).)

Note that the legacy features of swarm are not discussed, as those are
considered (more or less) deprecated. This includes the following packages:

* `swarm.client`
* `swarm.common`
* `swarm.protocol`

# Protocol Overview

The swarm protocol consists of the following components:

* TCP transport layer.
* Protocol version handshake.
* Message protocol.
* Authentication protocol.
* Request protocol.

## Protocol Version Handshake

After establishing the socket connection, each side sends a single byte
representing the protocol version. Each side then reads the byte from the other
side and checks the received version against its own. If there is a mismatch,
no further communication can occur.

## Message Protocol

Subsequent stages of the protocol transmit all data in the form of messages,
where a message consists of:

* A message header.
* A message body (a.k.a. payload).

### Message Header

The message header specifies:

* The type of the message. The message may either form part of a _request_ or
  part of the _authentication_ process.
* The length of the message payload (bytes).
* A parity byte, used for error checking of the header.

### Message Body

The message payload is opaque data, at this level, specified by the
authentication or request protocol that is sending the message.

## Authentication Protocol

Once the protocol version has been confirmed to match, the identity of the
client is authenticated with the node. The client has a name and an
authentication key. The node has a list of the names and keys of clients which
are allowed access.

The protocol works as follows:

1. The client sends the current timestamp.
2. The node sends a nonce (a random number).
3. The client creates an HMAC code from its authorisation key, the timestamp it
   sent, and the nonce it received.
4. The client sends its name and the HMAC code to the node.
5. The node looks up the client's name and finds the corresponding key.
6. The node calculates an HMAC code from the client's key, the timestamp it
   received, and the nonce it sent.
7. If the node's HMAC matches the one received from the client, authentication
   succeeds.
8. The node sends a byte informing the client whether authentication was
   successful or not.

## Request Protocol

Once a connection is established and authenticated, the request protocol begins.
From this point onward, the protocol keeps the underlying socket active for
reading and writing at all times, allowing bidirectional (full
duplex) communication. (The previous stages of the protocol use half duplex.)

The connection uses one socket per client/node connection.
However, there may be more than one request between the same client and node
active at a time. Therefore the messages exchanged for these simultaneously
active requests have to be multiplexed through the same socket.
Furthermore, both parties, the server and the client can send data through the
socket connection at any time so they must always expect data to arrive
from the other party.

The request protocol works as follows:

* The first 64 bits of all message payloads contains the id of a request.
* Using this id, the client/node can look up the request to which a message is
  directed, and notify it that a message has arrived.
* If a message is received for a request id that does not exist, the message is
  simply discarded, with no effect.

Apart from the request id, the message payload is opaque data, at this level,
specified by the protocol for the specific request type that is sending the
message.

# Connection and Request Handling

Connection and request handling vary significantly between the client and node,
however there are many similarities. These are discussed in this section.

## Connections

One way to always expect and therefore be ready to handle incoming messages is
to separate the code for sending and receiving messages through the same socket.
This is done in `MessageReceiver` and `MessageSender`.
Both of which have the same principle of operation. They have:

* A message source, something which produces messages to be forwarded.
* A message sink, something where they forward the received messages to.
* An input queue from which they pop the messages which have been
  produced by the message source.
* A notification mechanism that there are now messages in the queue.
* A fiber which, in a loop, waits for the notification and then pops
  all messages from the queue and forwards it to the sink, one at a time.

For the message receiver:

* The message source is the socket.
* The message sink is a callback which passes the message on to the
  request it refers to (the delegate parameter of `MessageReceiver.receive`).
* The input queue is the socket input buffer.
* The notification mechanism is epoll.
* The fiber with the loop is `ConnectionBase.ReceiveLoop`.

For the message sender:

* The message sources are the requests.
* The message sink is the socket.
* The input queue is the queue of pending messages:
  `ConnectionBase.SendLoop.queue`.
* The notification mechanism is in
  `ConnectionBase.SendLoop.registerForSending`, which is called
  whenever a request wants to send a message.
* The fiber with the loop is `ConnectionBase.SendLoop`.

The `ConnectionBase` (`swarm.neo.connection.ConnectionBase`) combines
`MessageReceiver` and `MessageSender` in one class and provides the
basic functionality of one full-duplex node - client connection. It contains:

* The two fibers, one handling sending (using `MessageSender`) over the connection
  and one handling receiving (using `MessageReceiver`).
* The message dispatching logic that reads the request id from the message payload
  (the first 64 bits), looks up the appropriate request, and passes the
  remainder of the message payload to it.
* Then logic for registering the connection socket with epoll for I/O multiplexing.
  (A `ConnectionBase` object is an `ISelectClient`. See
  `ocean.io.select.client.model.ISelectClient`.)

Note that the read loop is always registered to epoll waiting for incoming messages
while the send loop usualy sends messages imediatly. The send loop only registeres
itself to epoll if the socket file descriptor is not ready for sending.

## Requests on Connections

A request can require access to any number of connections to send/receive over.
An instance of the `RequestOnConnBase` class
(`swarm.neo.connection.RequestOnConnBase`) denotes a unique combination of a
_request_ operating over a specific _connection_ (a request-on-connection),
providing the core functionality required for a request to transmit messages
over the connection . Requests on connections are commonly referred to as
"request-on-conns" or as "RoCs".

A request-on-conn has the following important components:

* A fiber that manages asynchronous I/O operations for the request on the
  connection.
* An event dispatcher (the nested class `EventDispatcher`) instance that
  provides the following functionality:
  - A method to suspend the RoC fiber and wait for one of a set of specified
    events. Events that can be waited on are:
    1. Receiving a payload for this request.
    2. Sending a payload.
    3. The fiber being resumed after it was yielded and an epoll event-loop
       cycle occurred.
    4. The fiber being resumed by user code with a non-negative code.
  - Helper methods encapsulating a few common use cases of waiting for an event:
    sending a payload, receiving a payload, receiving a payload containing a
    single value of the specified type.
  - A method to get the IP/port of the remote.
  - Methods to shut down the associated connection (for example, in case of a
    protocol error).
* A method to suspend the fiber. (Sometimes a request implementation needs to
  manually suspend and resume the RoC fiber based on events other than those
  managed by `RequestOnConnBase`.)
* A method to resume the fiber with either a numerical code or an exception.

# Client Overview

TODO topics to cover:
* Connection
* Connection set
* Request
* Request set
* Request handlers
* User notifiers

## Requests

TODO topics to cover:
* Request versioning
* Types of request
* Access to connections

# Node Overview

TODO topics to cover:
* Connection
* Connection set
* Request
* Request set
* Request handlers

## Requests

TODO topics to cover:
* Request versioning
* Types of request
* Access to connections
