/*******************************************************************************

    Mixin for method to serialize a record.

    Copyright:
        Copyright (c) 2018 dunnhumby Germany GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module swarm.neo.client.mixins.SerializeMethod;

import ocean.meta.types.Qualifiers;
import ocean.util.serialize.contiguous.MultiVersionDecorator;

/*******************************************************************************

    Mixin for method to serialize a record value.

    Params:
        dst = pointer to the buffer to be serialized into

*******************************************************************************/

template SerializeMethod ( alias dst )
{
    import ocean.util.serialize.contiguous.Contiguous;
    import ocean.util.serialize.Version;
    import ocean.util.serialize.contiguous.Serializer;
    import ocean.util.serialize.contiguous.MultiVersionDecorator;

    /***************************************************************************

        Serializes `src` into `dst`, using a version decorater, if required.

        Params:
            T = type of struct to serialize
            src = instance to serialize

    ***************************************************************************/

    public void serialize ( T ) ( T src )
    {
        static if ( Version.Info!(T).exists )
            VersionDecorator.store!(T)(src, *dst);
        else
            Serializer.serialize(src, *dst);
    }
}

version ( unittest )
{
    import ocean.core.Test;
    import ocean.util.serialize.contiguous.Contiguous;
    import ocean.util.serialize.contiguous.Deserializer;

    struct Request
    {
        void[]* value;
        mixin SerializeMethod!(value);
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
    auto value_buf = new void[32];
    r.name = "whatever".dup;
    r.id = 23;
    rq.value = &value_buf;
    rq.serialize(r);

    Contiguous!(Record) buf;
    auto deserialized = Deserializer.deserialize(*rq.value, buf).ptr;
    test!("==")(deserialized.name, r.name);
    test!("==")(deserialized.id, r.id);
}
