* `swarm.neo.authentication.ClientCredentials`

  * The new function `fromFile` creates a `Credentials` instance with the name
    and key set to values parsed from the specified credentials file.

  * The new method `Credentials.setFromFile` sets the name and key fields to
    values parsed from the specified credentials file.

* `swarm.neo.client.mixins.ClientCore`

  A new constructor has been added which accepts the path of a credentials file
  to read the client's auth name/key from (rather than passing the values of
  those fields manually to the constructor).

