## EventDispatcher.nextEvent doesn't implicitly allow explicit resume

`swarm.neo.connection.RequestOnConnBase`

The EventDispatcher.nextEvent method suspends the fiber and ensures that it is
only resumed again for an expected reason. Previously, in addition to the
resume reasons specified by the user when calling the method, manual resumption
of the fiber with a positive resume code was always implicitly allowed. This
meant that user code had to manually check for this case, if it was not
desired.

Now, manual resumption of the fiber is disallowed by default, and
EventDispatcher.nextEvent will by default treat this as a protocol error, if it
occurs. Code that calls nextEvent should be updated as follows:

   - If you wish to allow manual fiber resumption,
     pass the new NextEventFlags.Resume flag to nextEvent.
   - If you wish to disallow manual fiber resumption, do nothing. For tidiness,
     you should remove any user code that checks for this occurrence.
