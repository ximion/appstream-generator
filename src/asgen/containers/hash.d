/*
 * Copyright (c) 2018-2019 Igor Khasilev
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 */

module asgen.containers.hash;

import std.traits;

///
/// For classes (and structs with toHash method) we use v.toHash() to compute hash.
/// ===============================================================================
/// toHash method CAN BE @nogc or not. HashMap 'nogc' properties is inherited from this method.
/// toHash method MUST BE @safe or @trusted, as all HashMap code alredy safe.
///
/// See also: https://dlang.org/spec/hash-map.html#using_classes_as_key 
/// and https://dlang.org/spec/hash-map.html#using_struct_as_key
///
bool UseToHashMethod(T)() {
    return (is(T == class) || (is(T==struct) && __traits(compiles, {
        T v = T.init; hash_t h = v.toHash();
    })));
}

hash_t hash_function(T)(T v) /* @safe @nogc inherited from toHash method */
if ( UseToHashMethod!T )
{
    return v.toHash();
}

hash_t hash_function(T)(in T v) @nogc @trusted
if ( !UseToHashMethod!T )
{
    static if ( isNumeric!T ) {
        enum m = 0x5bd1e995;
        hash_t h = v;
        h ^= h >> 13;
        h *= m;
        h ^= h >> 15;
        return h;
    }
    else static if ( is(T == string) ) {
        // // FNV-1a hash
        // ulong h = 0xcbf29ce484222325;
        // foreach (const ubyte c; cast(ubyte[]) v)
        // {
        //     h ^= c;
        //     h *= 0x100000001b3;
        // }
        // return cast(hash_t)h;
        import core.internal.hash : bytesHash;
        return bytesHash(cast(void*)v.ptr, v.length, 0);
    }
    else
    {
        const(ubyte)[] bytes = (cast(const(ubyte)*)&v)[0 .. T.sizeof];
        ulong h = 0xcbf29ce484222325;
        foreach (const ubyte c; bytes)
        {
            h ^= c;
            h *= 0x100000001b3;
        }
        return cast(hash_t)h;
    }
}

@safe unittest
{
    //assert(hash_function("abc") == cast(hash_t)0xe71fa2190541574b);

    struct A0 {}
    assert(!UseToHashMethod!A0);

    struct A1 {
        hash_t toHash() const @safe {
            return 0;
        }
        bool opEquals(const A1 other) const @safe {
            return other.toHash() == toHash();
        }
    }
    assert(UseToHashMethod!A1);

    // class with toHash override - will use toHash
    class C0 {
        override hash_t toHash() const @safe {
            return 0;
        }
        bool opEquals(const C0 other) const @safe {
            return other.toHash() == toHash();
        }
    }
    assert(UseToHashMethod!C0);
    C0 c0 = new C0();
    assert(c0.toHash() == 0);

    // class without toHash override - use Object.toHash method
    class C1 {
    }
    assert(UseToHashMethod!C1);
}
