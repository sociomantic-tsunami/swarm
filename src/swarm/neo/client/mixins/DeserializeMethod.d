/*******************************************************************************

    Mixin for method to deserialize a received record.

    Copyright:
        Copyright (c) 2017 dunnhumby Germany GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module swarm.neo.client.mixins.DeserializeMethod;

import ocean.transition;
import ocean.util.serialize.contiguous.MultiVersionDecorator;

/*******************************************************************************

    Mixin for method to deserialize a received record.

    Params:
        src = the buffer to be deserialized

*******************************************************************************/

template DeserializeMethod ( alias src )
{
    import ocean.util.serialize.contiguous.Contiguous;
    import ocean.util.serialize.Version;
    import ocean.util.serialize.contiguous.Deserializer;
    import ocean.util.serialize.contiguous.MultiVersionDecorator;

    /***************************************************************************

        Deserializes `src` into `dst`, using the provided version decorater, if
        required.

        Params:
            T = type of struct to deserialize
            dst = deserialization destination

        Returns:
            pointer to deserialized struct (points to the buffer inside dst)

    ***************************************************************************/

    public T* deserialize ( T ) ( ref Contiguous!(T) dst )
    {
        static if ( Version.Info!(T).exists )
        {
            if ( client_deserializer_version_decorator is null )
                client_deserializer_version_decorator = new VersionDecorator;

            return client_deserializer_version_decorator
                .loadCopy!(T)(src, dst).ptr;
        }
        else
        {
            return Deserializer.deserialize(src, dst).ptr;
        }
    }
}

/*******************************************************************************

    VersionDecorator singleton used by all mixed-in deserialize() methods when
    handling versioned structs.

    Must be public as it needs to be accessible from the point where the
    deserialize method is mixed in. Not intended to be used externally by users.
    The object is given an unusually long name so as to reduce the likelihood of
    name clashes with other symbols.

*******************************************************************************/

public VersionDecorator client_deserializer_version_decorator;

version ( UnitTest )
{
    import ocean.core.Test;
    import ocean.util.serialize.contiguous.Contiguous;
    import ocean.util.serialize.contiguous.Serializer;

    struct Request
    {
        void[] value;
        mixin DeserializeMethod!(value);
    }
}

unittest
{
    struct Record
    {
        mstring name;
        hash_t id;
    }

    Request rq;
    Record r;
    r.name = "whatever".dup;
    r.id = 23;
    void[] serialized;
    Serializer.serialize(r, rq.value);

    Contiguous!(Record) buf;
    auto deserialized = rq.deserialize(buf);
    test!("==")(deserialized.name, r.name);
    test!("==")(deserialized.id, r.id);
}
