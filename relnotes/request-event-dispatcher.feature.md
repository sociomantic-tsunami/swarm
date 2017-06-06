* `swarm.neo.request.RequestEventDispatcher`

  New helper struct for dispatching events from a single request-on-conn over
  multiple request handler fibers, each of which is responsible for a particular
  subset of possible events.

  For a practical example, see the GetAll request implementation in the test
  node (`test.neo.node.request.GetAll`).

