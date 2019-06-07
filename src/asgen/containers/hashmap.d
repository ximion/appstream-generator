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

module asgen.containers.hashmap;

import std.traits;
import std.format;
import std.typecons;

import core.memory;
import core.bitop;

private import std.experimental.allocator;
private import std.experimental.allocator.mallocator: Mallocator;
private import std.experimental.allocator.gc_allocator;

private import asgen.containers.hash;
private import asgen.containers.lists;
private import asgen.utils;

class KeyNotFound: Exception
{
    this(string msg = "key not found") @safe
    {
        super(msg);
    }
}

static if (hash_t.sizeof == 8)
{
    enum    EMPTY_HASH =     0x00_00_00_00_00_00_00_00;
    enum    DELETED_HASH =   0x10_00_00_00_00_00_00_00;
    enum    ALLOCATED_HASH = 0x20_00_00_00_00_00_00_00;
    enum    TYPE_MASK =      0xF0_00_00_00_00_00_00_00;
    enum    HASH_MASK =      0x0F_FF_FF_FF_FF_FF_FF_FF;
}
else static if (hash_t.sizeof == 4)
{
    enum    EMPTY_HASH =     0x00_00_00_00;
    enum    DELETED_HASH =   0x10_00_00_00;
    enum    ALLOCATED_HASH = 0x20_00_00_00;
    enum    TYPE_MASK =      0xF0_00_00_00;
    enum    HASH_MASK =      0x0F_FF_FF_FF;
}

///
/// Return true if it is worth to store values inline in hash table
/// V footprint should be small enough
///
package bool SmallValueFootprint(V)() {
    import std.traits;
    static if (
           isNumeric!V
        || isSomeString!V
        || isSomeChar!V
        || isPointer!V )
    {
            return true;
    }
    else static if (
           is(V == struct) && V.sizeof <= (void*).sizeof )
    {
            return true;
    }
    else static if (
            is(V == class ) && __traits(classInstanceSize, V) <= (void*).sizeof)
    {
        return true;
    }
    else
        return false;
}

private bool keyEquals(K)(K a, K b)
{
    static if ( is(K==class) )
    {
        if (a is b)
        {
            return true;
        }
        if (a is null || b is null)
        {
            return false;
        }
        return a.opEquals(b);
    }
    else
    {
        return a == b;
    }
}
@safe nothrow unittest
{
    class C
    {
        int c;
        this(int v)
        {
            c = v;
        }
        bool opEquals(const C other) const nothrow @safe
        {
            return c == other.c;
        }
        override size_t toHash() const nothrow @safe
        {
            return c;
	}
    }
    C a = new C(0);
    C b = new C(1);
    C c = a;
    C d = new C(0);
    assert(!keyEquals(a,b));
    assert(keyEquals(a,c));
    assert(keyEquals(a,d));
    assert(!keyEquals(null, a));
    assert(keyEquals(1,1));
}

///
struct HashMap(K, V, Allocator = Mallocator, bool GCRangesAllowed = true) {

    private enum initial_buckets_num = 32;

    alias StoredKeyType   = StoredType!K;
    alias StoredValueType = StoredType!V;

    private {
        alias   allocator = Allocator.instance;

        struct _Bucket {
            hash_t          hash;
            StoredKeyType   key;
            StoredValueType   value;
            string toString() const {
                import std.format;
                return "%s, hash: %0x,key: %s, value: %s".format(
                    [EMPTY_HASH:"free", DELETED_HASH:"deleted", ALLOCATED_HASH:"allocated"][cast(long   )(hash & TYPE_MASK)],
                    hash, key, value);
            }
        }

        _Bucket[]   _buckets;
        int         _buckets_num;
        int         _mask;
        int         _allocated;
        int         _deleted;
        int         _empty;

        int         _grow_factor = 4;

    }

    ~this() @safe {
        clear();
    }
    invariant {
        assert(_allocated>=0 && _deleted>=0 && _empty >= 0);
        assert(_allocated + _deleted + _empty == _buckets_num);
    }

    ///
    struct KeyPointer {

        private _Bucket*                                  _bucket;
        private hash_t                                    _hash;
        private HashMap!(K,V,Allocator, GCRangesAllowed)* _map;

        bool allocated() pure const nothrow @nogc {
            return _hash >= ALLOCATED_HASH;
        }

        V get() {
            static if ( is(V==StoredValueType) )
            {
                return _bucket.value;
            }
            else
            {
                return cast(V)_bucket.value;
            }
        }

        void set(V)(auto ref V v)
        {
            bool check_overload = false;
            debug(cachetools) safe_tracef("bucket: %s", *_bucket);
            if ( !allocated() )
            {
                _map._allocated++;
                if ( _bucket.hash == DELETED_HASH )
                {
                    _map._deleted--;
                }
                else
                {
                    _map._empty--;
                }
                _hash += ALLOCATED_HASH;
                _bucket.hash = _hash;
                check_overload = true;
            }
            static if ( is(V==StoredValueType) )
            {
                _bucket.value = v;
            }
            else
            {
                _bucket.value = cast(StoredValueType)v;
            }
            if ( check_overload && _map.tooHighLoad ) {
                _map.doResize(_map._grow_factor * _map._buckets_num);
            }
        }
    }

    ///
    public KeyPointer keyPointer(K key) {

        if ( !_buckets_num ) {
            _buckets_num = _empty = initial_buckets_num;
            assert(popcnt(_buckets_num) == 1, "Buckets number must be power of 2");
            _mask = _buckets_num - 1;
            _buckets = makeArray!(_Bucket)(allocator, _buckets_num);
            () @trusted {
                static if ( !is(Allocator == GCAllocator) && (UseGCRanges!K||UseGCRanges!V) ) {
                    GC.addRange(_buckets.ptr, _buckets_num * _Bucket.sizeof);
                }
            }();
        }

        hash_t computed_hash = hash_function(key) & HASH_MASK;
        immutable start_index = computed_hash & _mask;
        immutable placement_index = findUpdateIndex(start_index, computed_hash, key);
        assert(placement_index >= 0);

        immutable allocated = _buckets[placement_index].hash >= ALLOCATED_HASH;
        if ( !allocated )
        {
            // store key inline
            _buckets[placement_index].key = key;
        }
        else
        {
            computed_hash += ALLOCATED_HASH;
        }
        return KeyPointer(&_buckets[placement_index], computed_hash, &this);
    }
    // Find allocated bucket for given key and computed hash starting from start_index
    // Returns: index if bucket found or hash_t.max otherwise
    //
    // Inherits @nogc from K opEquals()
    //
    private hash_t findEntryIndex(const hash_t start_index, const hash_t hash, ref K key)
    in
    {
        assert(hash < DELETED_HASH);        // we look for real hash
        assert(start_index < _buckets_num); // start position inside array
    }
    do {
        hash_t index = start_index;

        do {
            immutable h = _buckets[index].hash;

            debug(cachetools) safe_tracef("test entry index %d (%s) for key %s", index, _buckets[index], key);

            if ( h == EMPTY_HASH ) {
                break;
            }

            if ( h >= ALLOCATED_HASH && (h & HASH_MASK) == hash && keyEquals(_buckets[index].key, key) ) {
                //() @nogc @trusted {debug(cachetools) tracef("test entry index %d for key %s - success", index, key);}();
                return index;
            }
            index = (index + 1) & _mask;
        } while(index != start_index);
        return hash_t.max;
    }

    //
    // Find place where we can insert(DELETED or EMPTY bucket) or update existent (ALLOCATED)
    // bucket for key k and precomputed hash starting from start_index
    //
    //
    // Inherits @nogc from K opEquals()
    //
    private hash_t findUpdateIndex(const hash_t start_index, const hash_t computed_hash, ref K key)
    in 
    {
        assert(computed_hash < DELETED_HASH);
        assert(start_index < _buckets_num);
    }
    do {
        hash_t index = start_index;

        do {
            immutable h = _buckets[index].hash;

            debug(cachetools) safe_tracef("test update index %d (%s) for key %s", index, _buckets[index], key);

            if ( h <= DELETED_HASH ) // empty or deleted
            {
                debug(cachetools) safe_tracef("test update index %d (%s) for key %s - success", index, _buckets[index], key);
                return index;
            }
            assert((h & TYPE_MASK) == ALLOCATED_HASH);
            if ( (h & HASH_MASK) == computed_hash && keyEquals(_buckets[index].key, key) ) 
            {
                debug(cachetools) safe_tracef("test update index %d (%s) for key %s - success", index, _buckets[index], key);
                return index;
            }
            index = (index + 1) & _mask;
        } while(index != start_index);
        return hash_t.max;
    }
    //
    // Find unallocated entry in the buckets slice
    // We use this function during resize() only.
    //
    private long findEmptyIndexExtended(const hash_t start_index, in ref _Bucket[] buckets, int new_mask) pure const @safe @nogc
    in
    {
        assert(start_index < buckets.length);
    }
    do
    {
        hash_t index = start_index;

        do {
            immutable t = buckets[index].hash;

            debug(cachetools) safe_tracef("test empty index %d (%s)", index, buckets[index]);
            
            if ( t <= DELETED_HASH ) // empty or deleted
            {
                return index;
            }

            index = (index + 1) & new_mask;
        } while(index != start_index);
        return hash_t.max;
    }

    private bool tooMuchDeleted() pure const @safe @nogc {
        //
        // _deleted > _buckets_num / 8
        //
        return _deleted << 3 > _buckets_num;
    }

    private bool tooHighLoad() pure const @safe @nogc {
        //
        // _allocated/_buckets_num > 0.8
        // 5 * allocated > 4 * buckets_num
        //
        return _allocated + (_allocated << 2) > _buckets_num << 2;
    }

    private void doResize(int dest) {
        immutable _new_buckets_num = dest;
        immutable _new_mask = dest - 1;
        _Bucket[] _new_buckets = makeArray!(_Bucket)(allocator, _new_buckets_num);

        static if ( UseGCRanges!(Allocator, K, V, GCRangesAllowed) ) {
            () @trusted
            {
                GC.addRange(_new_buckets.ptr, _new_buckets_num * _Bucket.sizeof);
            }();
        }

        // iterate over entries

        debug(cachetools) safe_tracef("start resizing: old loadfactor: %s", (1.0*_allocated) / _buckets_num);

        for(int i=0;i<_buckets_num;i++) {
            immutable hash_t h = _buckets[i].hash;
            if ( h < ALLOCATED_HASH ) { // empty or deleted
                continue;
            }

            immutable hash_t start_index = h & _new_mask;
            immutable new_position = findEmptyIndexExtended(start_index, _new_buckets, _new_mask);

            debug(cachetools) safe_tracef("old hash: %0x, old pos: %d, new_pos: %d", h, i, new_position);

            assert( new_position >= 0 );
            assert( _new_buckets[cast(hash_t)new_position].hash  == EMPTY_HASH );

            _new_buckets[cast(hash_t)new_position] = _buckets[i];
        }
        () @trusted {
            static if ( UseGCRanges!(Allocator, K, V, GCRangesAllowed) ) {
               GC.removeRange(_buckets.ptr);
            }
            dispose(allocator, _buckets.ptr);
        }();
        _buckets = _new_buckets;
        _buckets_num = _new_buckets_num;
        _mask = _buckets_num - 1;
        _deleted = 0;
        _empty = _buckets_num - _allocated;

        assert(popcnt(_buckets_num) == 1, "Buckets number must be power of 2");
        debug(cachetools) safe_tracef("resizing done: new loadfactor: %s", (1.0*_allocated) / _buckets_num);
    }

    //
    // Lookup methods
    //

    /// key in table
    /// Returns: pointer to stored value (if key in table) or null 
    ///
    V* opBinaryRight(string op)(K k) if (op == "in")
    {

        if ( _buckets_num == 0 ) return null;

        immutable computed_hash = hash_function(k) & HASH_MASK;
        immutable start_index = computed_hash & _mask;
        immutable lookup_index = findEntryIndex(start_index, computed_hash, k);
        if ( lookup_index == hash_t.max) {
            return null;
        }
        static if ( is(V==StoredValueType) )
        {
            return &_buckets[lookup_index].value;
        }
        else
        {
            V* r = () @trusted {return cast(V*)&_buckets[lookup_index].value;}();
            return r;
        }
    }

    ///
    /// get value from hash or add if key is not in table. defaultValue can be callable.
    /// Returns: ref to value (maybe added)
    ///
    ref V getOrAdd(T)(K k, T defaultValue)
    {
        V* v = k in this;
        if ( v )
        {
            return *v;
        }
        static if ( is(T == V) || isAssignable!(V, T))
        {
            return *put(k, defaultValue);
        }
        else static if ( isCallable!T && isAssignable!(V, ReturnType!T))
        {
            return *put(k, defaultValue());
        }
        else
        {
            static assert(0, "what?");
        }
    }

    ///
    /// Check if the given key is contained in the hash map.
    ///
    bool contains(K k)
    {
        V* v = k in this;
        return v !is null;
    }

    ///
    alias require = getOrAdd;

    /// get current grow factor.
    auto grow_factor() const @safe {
        return _grow_factor;
    }

    /// set grow factor (can be between 2, 4 or 8).
    void grow_factor(int gf) @safe {
        if ( gf < 2 )
        {
            _grow_factor = 2;
            return;
        }
        if ( gf > 8 )
        {
            _grow_factor = 8;
            return;
        }
        // enforce new grow_factor is power of 2
        if ( popcnt(gf) > 1 )
        {
            immutable p = bsr(gf);
            gf = 1 << (p+1);
        }
        _grow_factor = gf;
    }
    ///
    /// get
    /// Returns: value from hash, or defaultValue if key not found (see also getOrAdd).
    /// defaultValue can be callable.
    ///
    V get(T)(K k, T defaultValue)
    {
        V* v = k in this;
        if ( v )
        {
            return *v;
        }
        static if (is(V == T) || isAssignable!(V, T))
        {
            return defaultValue;
        }
        else static if ( isCallable!T && isAssignable!(V, ReturnType!T))
        {
            return defaultValue();
        }
        else
        {
            static assert(0, "You must call 'get' with default value of HashMap 'value' type, or with callable, returning HashMap 'value'");
        }
    }

    ///
    /// map[key]
    /// Attention: you can't use this method in @nogc code.
    /// Usual aa[key] method.
    /// Throws exception if key not found
    /// Returns: value for given key
    ///
    ref V opIndex(K k)
    {
        V* v = k in this;
        if ( v !is null )
        {
            return *v;
        }
        throw new KeyNotFound();
    }

    ///
    /// map[k] = v;
    ///
    void opIndexAssign(V v, K k)
    {
        put(k, v);
    }
    ///
    /// put pair (k,v) into hash.
    ///
    /// it must be @safe, it inherits @nogc properties from K and V
    /// It can resize table if table is overloaded or has too much deleted entries.
    /// Returns: pointer to placed value (pointer is valid until next resize).
    ///
    V* put(K k, V v)
    out
    {
        assert(__result !is null);
    }
    do {
        if ( !_buckets_num ) {
            _buckets_num = _empty = initial_buckets_num;
            assert(popcnt(_buckets_num) == 1, "Buckets number must be power of 2");
            _mask = _buckets_num - 1;
            _buckets = makeArray!(_Bucket)(allocator, _buckets_num);
            () @trusted {
                static if ( UseGCRanges!(Allocator, K, V, GCRangesAllowed) ) {
                    GC.addRange(_buckets.ptr, _buckets_num * _Bucket.sizeof);
                }
            }();
        }

        debug(cachetools) safe_tracef("put k: %s, v: %s", k,v);

        if ( tooHighLoad ) {
            doResize(_grow_factor * _buckets_num);
        }

        V* r; //result
        immutable computed_hash = hash_function(k) & HASH_MASK;
        immutable start_index = computed_hash & _mask;
        immutable placement_index = findUpdateIndex(start_index, computed_hash, k);

        _Bucket* bucket = &_buckets[placement_index];
        immutable h = bucket.hash;

        debug(cachetools) safe_tracef("start_index: %d, placement_index: %d", start_index, placement_index);

        if ( h < ALLOCATED_HASH )
        {
            final switch(h) {
                case EMPTY_HASH:
                    _empty--;
                    break;
                case DELETED_HASH:
                    _deleted--;
                    break;
            }
            _allocated++;
            bucket.key = k;
        }
        debug(cachetools) safe_tracef("place inline buckets[%d] '%s'='%s'", placement_index, k, v);
        bucket.value = v;
        static if ( is(V==StoredValueType) )
        {
            r = &bucket.value;
        }
        else
        {
            () @trusted {r = cast(V*)&bucket.value;}();
        }
        bucket.hash = computed_hash | ALLOCATED_HASH;
        return r;
    }

    ///
    /// remomve key from hash.
    /// Returns: true if actually removed, false otherwise.
    ///
    bool remove(K k) {

        if ( tooMuchDeleted ) {
            // do not shrink, just compact table
            doResize(_buckets_num);
        }

        if ( _buckets_num == 0 ){
            return false;
        }

        debug(cachetools) safe_tracef("remove k: %s", k);

        immutable computed_hash = hash_function(k) & HASH_MASK;
        immutable start_index = computed_hash & _mask;
        immutable lookup_index = findEntryIndex(start_index, computed_hash, k);
        if ( lookup_index == hash_t.max )
        {
            // nothing to remove
            return false;
        }

        assert((_buckets[lookup_index].hash & TYPE_MASK) == ALLOCATED_HASH, "tried to remove non allocated bucket");

        _allocated--;
        immutable next_index = (lookup_index + 1) & _mask;
        // if next bucket is EMPTY, then we can convert all DELETED buckets down staring from current to EMPTY buckets
        if ( _buckets[next_index].hash == EMPTY_HASH )
        {
            _empty++;
            _buckets[lookup_index].hash = EMPTY_HASH;
            auto free_index = (lookup_index - 1) & _mask;
            while (free_index != lookup_index) {
                if ( _buckets[free_index].hash != DELETED_HASH ) {
                    break;
                }
                _buckets[free_index].hash = EMPTY_HASH;
                _deleted--;
                _empty++;
                free_index = (free_index - 1) & _mask;
            }
            assert(free_index != lookup_index, "table full of deleted buckets?");
        }
        else
        {
            _buckets[lookup_index].hash = DELETED_HASH;
            _deleted++;
        }
        return true;
    }
    /// throw away all keys
    void clear() @safe 
    {
        if ( _buckets_num > 0 )
        {
            () @trusted {
                static if ( !is(Allocator == GCAllocator) && (UseGCRanges!K||UseGCRanges!V) ) {
                    GC.removeRange(_buckets.ptr);
                }
                dispose(allocator, _buckets.ptr);
            }();
        }

        _buckets = null;
        _allocated = _deleted = _empty = _buckets_num = 0;
    }
    /// get numter of keys in table
    auto length() const pure nothrow @nogc @safe
    {
        return _allocated;
    }

    /// whether the table contains any keys
    bool empty() const pure nothrow @nogc @safe
    {
        return _allocated == 0;
    }

    /// get current buckets number
    auto size() const pure nothrow @nogc @safe
    {
        return _buckets_num;
    }

    /// iterator by keys
    auto byKey() pure @safe @nogc
    {
        struct _kvRange {
            int         _pos;
            ulong       _buckets_num;
            _Bucket[]   _buckets;
            this(_Bucket[] _b)
            {
                _buckets = _b;
                _buckets_num = _b.length;
                _pos = 0;
                while( _pos < _buckets_num  && _buckets[_pos].hash < ALLOCATED_HASH )
                {
                    _pos++;
                }
            }
            bool empty() const pure nothrow @safe @nogc {
                return _pos == _buckets_num;
            }

            K front() {
                return _buckets[_pos].key;
            }

            void popFront() pure nothrow @safe @nogc {
                _pos++;
                while( _pos < _buckets_num && _buckets[_pos].hash <  ALLOCATED_HASH )
                {
                    _pos++;
                }
            }
        }
        return _kvRange(_buckets);
    }

    /// iterator by values
    auto byValue() pure @safe {
        struct _kvRange {
            int         _pos;
            ulong       _buckets_num;
            _Bucket[]   _buckets;
            this(_Bucket[] _b)
            {
                _buckets = _b;
                _buckets_num = _b.length;
                _pos = 0;
                while( _pos < _buckets_num  && _buckets[_pos].hash < ALLOCATED_HASH )
                {
                    _pos++;
                }
            }
            bool empty() const pure nothrow @safe @nogc {
                return _pos == _buckets_num;
            }

            V front() {
                return _buckets[_pos].value;
            }

            void popFront() pure nothrow @safe @nogc {
                _pos++;
                while( _pos < _buckets_num && _buckets[_pos].hash < ALLOCATED_HASH )
                {
                    _pos++;
                }
            }
        }
        return _kvRange(_buckets);
    }

    /// iterator by key/value pairs
    auto byPair() pure @safe
    {
        import std.typecons;

        struct _kvRange {
            int         _pos;
            ulong       _buckets_num;
            _Bucket[]   _buckets;
            this(_Bucket[] _b)
            {
                _buckets = _b;
                _buckets_num = _b.length;
                _pos = 0;
                while( _pos < _buckets_num  && _buckets[_pos].hash < ALLOCATED_HASH )
                {
                    _pos++;
                }
            }
            bool empty() const pure nothrow @safe @nogc
            {
                return _pos == _buckets_num;
            }
            auto front() @safe
            {
                return Tuple!(K, "key", V, "value")(_buckets[_pos].key, _buckets[_pos].value);
            }
            void popFront() pure nothrow @safe @nogc
            {
                _pos++;
                while( _pos < _buckets_num && _buckets[_pos].hash < ALLOCATED_HASH )
                {
                    _pos++;
                }
            }
        }
        return _kvRange(_buckets);
    }
}

/// Example
@safe unittest {
    import std.range;
    import std.algorithm;

    HashMap!(string, int) counter;
    string[] words = ["hello", "this", "simple", "example", "should", "succeed", "or", "it", "should", "fail"];
    // count words, simplest and fastest way
    foreach (word; words)
    {
        counter.getOrAdd(word, 0)++;
    }
    assert("world" !in counter);
    assert(counter["hello"] == 1);
    assert(counter["should"] == 2);
    assert(counter.length == cast(int)(words.length) - 1);
    // clear counter
    counter.clear;
    assert(counter.length == 0);
    // more verbose way to count
    foreach (word; words)
    {
        auto w = word in counter;
        if (w)
        {
            (*w)++;
        }
        else
        {
            counter[word] = 1;
        }
    }
    assert("world" !in counter);
    assert(counter["hello"] == 1);
    assert(counter["should"] == 2);
    assert(counter.length == cast(int)(words.length) - 1);
    // iterators
    assert(counter.byKey.count == counter.byValue.count);
    assert(words.all!(w => w in counter));          // all words are in table
    assert(counter.byValue.sum == words.length);    // sum of counters must equals to number of words
}
// Tests
@safe unittest
{
    // test of nogc getOrAdd
    import std.experimental.logger;
    globalLogLevel = LogLevel.info;
    import std.meta;
    static foreach(T; AliasSeq!(HashMap!(int, int))) {
        () @nogc nothrow
        {
            T hashMap;
            debug(cachetools) safe_tracef("Testing %s", typeid(T));
            foreach (i;0..10) {
                hashMap.put(i, i);
            }
            foreach (i;0..10) {
                hashMap.put(i, i);
            }
            foreach (i;0..10) {
                assert(i==*(i in hashMap));
            }
            assert(hashMap.length == 10);
            hashMap.remove(0);
            assert(hashMap.length == 9);
            assert((0 in hashMap) is null);
            hashMap.remove(1);
            assert(hashMap.length == 8);
            assert((1 in hashMap) is null);
            assert(8 in hashMap);
            hashMap.remove(8);
            assert(hashMap.length == 7);
            assert((8 in hashMap) is null);
            foreach (i;0..10) {
                hashMap.put(i, i);
            }
            assert(hashMap.length == 10);
            hashMap.remove(8);
            hashMap.remove(1);
            assert(hashMap.length == 8);
            assert((1 in hashMap) is null);
            assert((8 in hashMap) is null);
            assert(hashMap.remove(1) == false);
            foreach (i;0..10) {
                hashMap.remove(i);
            }
            assert(hashMap.length == 0);
        }();
    }
    //auto v = hashMap.getOrAdd(-1, -1);
    //assert(-1 in hashMap && v == -1);
    globalLogLevel = LogLevel.info;
}

// test get()
@safe @nogc nothrow unittest
{
    import std.meta;
    static foreach(T; AliasSeq!(HashMap!(int, int))) {
        {
            T hashMap;
            int i = hashMap.get(1, 55);
            assert(i == 55);
            i = hashMap.get(1, () => 66);
            assert(i == 66);
            hashMap[1] = 1;
            i = hashMap.get(1, () => 66);
            assert(i == 1);
        }
    }
}
@safe unittest
{
    import std.meta;
    import std.stdio;
    static foreach(T; AliasSeq!(HashMap!(int, int))) {
        {
            T hashMap;
            hashMap[1]=1;
            assert( 1 in hashMap);
            assert( 2 !in hashMap);

            auto kp1 = hashMap.keyPointer(1);
            assert(kp1.allocated);
            kp1.set(11);
            assert(kp1.get() == 11);
            assert(hashMap[1] == 11);

            auto kp2 = hashMap.keyPointer(2);
            assert(!kp2.allocated);
            kp2.set(2);
            assert(kp2.allocated);
            assert(kp2.get() == 2);
            assert(hashMap[2] == 2);
            assert(hashMap.length == 2);
        }
    }
    struct S
    {
        int s;
    }
    HashMap!(immutable S, int) isHashMap;
    immutable ss = S(1);
    isHashMap[ss] = 1;
    assert(ss in isHashMap && *(ss in isHashMap) == 1);
    auto kp1 = isHashMap.keyPointer(ss);
    assert( kp1.allocated );
    assert( kp1.get() == 1);
    kp1.set(2);
    assert( isHashMap[ss] == 2);
}


// test immutable struct and class as Key type
@safe unittest
{
    import std.experimental.logger;
    globalLogLevel = LogLevel.info;
    info("Testing hash tables");
    import std.meta;
    struct S
    {
        int s;
    }
    static foreach(T; AliasSeq!(HashMap!(immutable S, int))) {
        () @nogc nothrow
        {
            T hs1;
            immutable ss = S(1);
            hs1[ss] = 1;
            assert(ss in hs1 && *(ss in hs1) == 1);
        }();
    }
    static foreach(T; AliasSeq!(HashMap!(int, immutable S))) {
        () @nogc nothrow
        {
            T hs2;
            immutable ss = S(1);
            hs2[1] = ss;
            assert(1 in hs2 && *(1 in hs2) == ss);
            assert(!(2 in hs2));
        }();
    }
    // class
    class C
    {
        int v;
        this(int _v) pure inout
        {
            v = _v;
        }
        bool opEquals(const C o) pure const @safe @nogc nothrow {
            return v == o.v;
        }
        override hash_t toHash() const @safe @nogc {
            return hash_function(v);
        }
    }
    static foreach(T; AliasSeq!(HashMap!(immutable C, int)))
    {
        {
            T hc1;
            immutable cc = new immutable C(1);
            hc1[cc] = 1;
            assert(hc1[cc] == 1);
        }
    }
    static foreach(T; AliasSeq!(HashMap!(int, immutable C)))
    {
        {
            immutable cc = new immutable C(1);
            T hc2;
            hc2[1] = cc;
            assert(hc2[1] is cc);
        }
    }
}
@safe unittest {
    // test class as key
    import std.experimental.logger;
    globalLogLevel = LogLevel.info;
    class A {
        int v;

        bool opEquals(const A o) pure const @safe @nogc nothrow {
            return v == o.v;
        }
        override hash_t toHash() const @safe @nogc {
            return hash_function(v);
        }
        this(int v)
        {
            this.v = v;
        }
        override string toString() const
        {
            import std.format;
            return "A(%d)".format(v);
        }
    }

    globalLogLevel = LogLevel.info;
    auto x = new A(1);
    auto y = new A(2);
    HashMap!(A, string) dict;
    dict.put(x, "x");
    dict.put(y, "y");
}

@safe unittest {
    import std.experimental.logger;
    globalLogLevel = LogLevel.info;
    () @nogc nothrow {
        HashMap!(int, int) int2int;
        foreach(i; 0..15) {
            int2int.put(i,i);
        }
        assert(int2int.length() == 15);
        foreach(i; 0..15) {
            assert(i in int2int);
        }
        foreach(i; 0..15) {
            int2int.remove(i);
        }
        assert(int2int.length() == 0);
    }();
    () @nogc nothrow {
        struct LargeStruct {
            ulong a;
            ulong b;
        }
        HashMap!(int, LargeStruct) int2ls;
        foreach(i; 1..5) {
            int2ls.put(i,LargeStruct(i,i));
        }
        int2ls.put(33,LargeStruct(33,33)); // <- follow key 1, move key 2 on pos 3
        assert(1 in int2ls, "1 not in hash");
        assert(2 in int2ls, "2 not in hash");
        assert(3 in int2ls, "3 not in hash");
        assert(4 in int2ls, "4 not in hash");
        assert(33 in int2ls, "33 not in hash");
        int2ls.remove(33);
        int2ls.put(2,LargeStruct(2,2)); // <- must replace key 2 on pos 3
        assert(2 in int2ls, "2 not in hash");
    }();
}

@safe unittest {
    import std.experimental.logger;
    globalLogLevel = LogLevel.info;
    () @nogc nothrow {
        assert(SmallValueFootprint!int());
        assert(SmallValueFootprint!double());
        struct SmallStruct {
            ulong a;
        }
        //assert(SmallValueFootprint!SmallStruct);
        struct LargeStruct {
            ulong a;
            ulong b;
        }
        assert(!SmallValueFootprint!LargeStruct);
        class SmallClass {
            ulong a;
        }
        //assert(!SmallValueFootprint!SmallClass);

        HashMap!(int, string) int2string;
        auto u = int2string.put(1, "one");
        {
            auto v = 1 in int2string;
            assert(v !is null);
            assert(*v == "one");
        }
        assert(2 !in int2string);
        u = int2string.put(32+1, "33");
        assert(33 in int2string);
        assert(int2string.remove(33));
        assert(!int2string.remove(33));
        
        HashMap!(int, LargeStruct) int2LagreStruct;
        int2LagreStruct.put(1, LargeStruct(1,2));
        {
            auto v = 1 in int2LagreStruct;
            assert(v !is null);
            assert(*v == LargeStruct(1, 2));
        }
    }();

    globalLogLevel = LogLevel.info;
}

@safe unittest {
    import std.experimental.logger;
    import std.experimental.allocator.gc_allocator;
    globalLogLevel = LogLevel.info;
    static int i;
    () @safe @nogc nothrow {
        struct LargeStruct {
            ulong a;
            ulong b;
            ~this() @safe @nogc {
                i++;
            }
        }
        HashMap!(int, LargeStruct) int2LagreStruct;
        int2LagreStruct.put(1, LargeStruct(1,2));
    }();
    globalLogLevel = LogLevel.info;
}

@safe unittest /* not nothrow as opIndex may throw */
{
    import std.typecons;
    alias K = Tuple!(int, int);
    alias V = int;
    HashMap!(K,V) h;
    K k0 = K(0,1);
    V v0 = 1;
    h.put(k0, v0);
    int *v = k0 in h;
    assert(v);
    assert(*v == 1);
    h[k0] = v0;
    assert(h[k0] == v0);
}

@safe nothrow unittest
{
    class c {
        int a;
        this(int a)
        {
            this.a = a;
        }
        override hash_t toHash() const pure @nogc @safe
        {
            return hash_function(a);
        }
        bool opEquals(const c other) pure const nothrow @safe @nogc
        {
            return this is other || this.a == other.a;
        }
    }
    alias K = c;
    alias V = int;
    K k0 = new c(0);
    V v0 = 1;
    () @nogc nothrow {
        HashMap!(K,V) h;
        h.put(k0, v0);
        int *v = k0 in h;
        assert(v);
        assert(*v == 1);
        h[k0] = 2;
        v = k0 in h;
        assert(*v == 2);
    }();
}

// Test if we can work with non-@nogc opEquals for class-key.
// opEquals anyway must be non-@system.
@safe nothrow unittest
{
    class c {
        int a;
        this(int a)
        {
            this.a = a;
        }
        override hash_t toHash() const pure @safe
        {
            int[] _ = [1, 2, 3]; // this cause GC
            return hash_function(a);
        }

        bool opEquals(const c other) const pure nothrow @safe
        {
            auto _ = [1,2,3]; // this cause GC
            return this is other || this.a == other.a;
        }
    }
    alias K = c;
    alias V = int;
    HashMap!(K,V) h;
    K k0 = new c(0);
    V v0 = 1;
    h.put(k0, v0);
    int *v = k0 in h;
    assert(v);
    assert(*v == 1);
    K k1 = new c(1);
    h.put(k0, v0);
    assert(!keyEquals(k0, k1));
}
//
// test byKey, byValue, byPair
//
@safe nothrow unittest
{
    import std.algorithm;
    import std.array;
    import std.stdio;

    HashMap!(int, string) m;
    m[1] = "one";
    m[2] = "two";
    m[10] = "ten";
    assert(equal(m.byKey.array.sort, [1,2,10]));
    assert(equal(m.byValue.array.sort, ["one", "ten", "two"]));
    assert(equal(
        m.byPair.map!"tuple(a.key, a.value)".array.sort, 
        [tuple(1, "one"), tuple(2, "two"), tuple(10, "ten")]
    ));
    m.remove(1);
    m.remove(10);
    assert(equal(
    m.byPair.map!"tuple(a.key, a.value)".array.sort,
        [tuple(2, "two")]
    ));
    m.remove(2);
    assert(m.byPair.map!"tuple(a.key, a.value)".array.sort.length() == 0);
    m.remove(2);
    assert(m.byPair.map!"tuple(a.key, a.value)".array.sort.length() == 0);
}
// test byKey, byValue, byPair compiles with GCRangesAllowed=false
@nogc unittest
{
    import std.experimental.allocator.mallocator : Mallocator;

    HashMap!(int, int, Mallocator, false) map;
    map[1] = 2;

    auto keys = map.byKey();
    assert(keys.empty == false);
    assert(keys.front == 1);

    auto values = map.byValue();
    assert(values.empty == false);
    assert(values.front == 2);

    auto pairs = map.byPair();
    assert(pairs.empty == false);
    assert(pairs.front.key == 1);
    assert(pairs.front.value == 2);
}
// 
// compare equivalence to AA
//
/* not @safe because of AA */ unittest {
    import std.random;
    import std.array;
    import std.algorithm;
    import std.stdio;
    import std.experimental.logger;

    enum iterations = 400_000;

    globalLogLevel = LogLevel.info;

    HashMap!(int, int) hashMap;
    int[int]             AA;

    auto rnd = Random(unpredictableSeed);

    foreach(i;0..iterations) {
        int k = uniform(0, iterations, rnd);
        hashMap.put(k, i);
        AA[k] = i;
    }
    assert(equal(AA.keys().sort(), hashMap.byKey().array.sort()));
    assert(equal(AA.values().sort(), hashMap.byValue().array.sort()));
    assert(AA.length == hashMap.length);
}
//
// check remove
//
@safe unittest
{
    // test removal while iterating
    import std.random;
    import std.array;
    import std.algorithm;
    import std.stdio;
    import std.experimental.logger;

    enum iterations = 400_000;

    globalLogLevel = LogLevel.info;

    HashMap!(int, int) hashMap;

    auto rnd = Random(unpredictableSeed);

    foreach(i;0..iterations) {
        int k = uniform(0, iterations, rnd);
        hashMap[k] = i;
    }
    foreach(k; hashMap.byKey)
    {
        assert(hashMap.remove(k));
    }
    assert(hashMap.length == 0);
}
//
// test clear
//
@safe @nogc nothrow unittest
{
    // test clear

    HashMap!(int, int) hashMap;

    foreach(i;0..100) {
        hashMap[i] = i;
    }
    hashMap.clear();
    assert(hashMap.length == 0);
    hashMap[1] = 1;
    assert(1 in hashMap && hashMap.length == 1);
}
//
// test getOrAdd with value
//
@safe @nogc nothrow unittest
{
    // test of nogc getOrAdd

    HashMap!(int, int) hashMap;

    foreach(i;0..100) {
        hashMap[i] = i;
    }
    auto v = hashMap.getOrAdd(-1, -1);
    assert(-1 in hashMap && v == -1);
}

//
// test getOrAdd with callable
//
@safe @nogc nothrow unittest
{
    // test of nogc getOrAdd with lazy default value

    HashMap!(int, int) hashMap;

    foreach(i;0..100) {
        hashMap[i] = i;
    }
    int v = hashMap.getOrAdd(-1, () => -1);
    assert(-1 in hashMap && v == -1);
    assert(hashMap.get(-1, 0) == -1); // key -1 is in hash, return value
    assert(hashMap.get(-2, 0) == 0);  // key -2 not in map, return default value
    assert(hashMap.get(-3, () => 0) == 0);  // ditto
}

//
// test getOrAdd with complex  data
//
@safe unittest
{
    import std.socket, std.meta;
    static foreach(T; AliasSeq!(HashMap!(string, Socket)))
    {
        {
            T socketPool;
            Socket s0 = socketPool.getOrAdd("http://example.com", () => new Socket(AddressFamily.INET, SocketType.STREAM));
            assert(s0 !is null);
            assert(s0.addressFamily == AddressFamily.INET);
            Socket s1 = socketPool.getOrAdd("http://example.com", () => new Socket(AddressFamily.INET, SocketType.STREAM));
            assert(s1 !is null);
            assert(s1 is s0);
        }
    }
}
//
// test with real class (socket)
//
@safe unittest
{
    import std.socket;
    class Connection {
        Socket s;
        bool opEquals(const Connection other) const pure @safe
        {
            return s is other.s;
        }
        override hash_t toHash() const @safe
        {
            return hash_function(s.handle);
        }
        this() {
            s = new Socket(AddressFamily.INET, SocketType.STREAM);
        }
    }
    HashMap!(Connection, string) socketPool;
    auto c1 = new Connection();
    auto c2 = new Connection();
    socketPool[c1] = "conn1";
    socketPool[c2] = "conn2";
    assert(socketPool[c1] == "conn1");
    assert(socketPool[c2] == "conn2");
}

@safe unittest
{
    // test of non-@nogc getOrAdd with lazy default value
    import std.conv;
    import std.exception;
    import std.experimental.logger;
    import std.meta;

    globalLogLevel = LogLevel.info;
    class C {
        string v;
        this(int _v) @safe
        {
            v = to!string(_v);
        }
    }
    static foreach(T; AliasSeq!(HashMap!(int, C)))
    {
        {
            T hashMap;

            foreach(i;0..100) {
                hashMap[i] = new C(i);
            }
            C v = hashMap.getOrAdd(-1, () => new C(-1));
            assert(-1 in hashMap && v.v == "-1");
            assert(hashMap[-1].v == "-1");
            hashMap[-1].v ~= "1";
            assert(hashMap[-1].v == "-11");
            assertThrown!KeyNotFound(hashMap[-2]);
            // check lazyness
            bool called;
            v = hashMap.getOrAdd(-1, delegate C() {called = true; return new C(0);});
            assert(!called);
            v = hashMap.getOrAdd(-2, delegate C() {called = true; return new C(0);});
            assert(called);
        }
    }
}
//
// test if we can handle some exotic value type
//
@safe @nogc nothrow unittest
{
    // test of nogc getOrAdd with lazy default value
    // corner case when V is callable

    alias F = int function() @safe @nogc nothrow;

    F one = function()
    {
        return 1;
    };
    F two = function()
    {
        return 2;
    };
    F four = function()
    {
        return 4;
    };
    HashMap!(int, F) hashMap;
    hashMap.put(1, one);
    hashMap.put(2, two);
    auto p = 1 in hashMap;
    assert(p);
    assert((*p)() == 1);
    p = 2 in hashMap;
    assert(p);
    assert((*p)() == 2);
    auto f3 = hashMap.getOrAdd(3, () => function int() {return 3;}); // used as default()
    assert(f3() == 3);
    auto f4 = hashMap.getOrAdd(4, four);
    assert(f4() == 4);
}

// test get()
@safe @nogc nothrow unittest
{
    HashMap!(int, int) hashMap;
    int i = hashMap.get(1, 55);
    assert(i == 55);
    i = hashMap.get(1, () => 66);
    assert(i == 66);
    hashMap[1] = 1;
    i = hashMap.get(1, () => 66);
    assert(i == 1);
}
// test grow_factor()
unittest
{
    import std.experimental.logger;
    globalLogLevel = LogLevel.info;
    HashMap!(int, int) hashMap;
    hashMap.grow_factor(3);
    assert(hashMap.grow_factor() == 4);
    hashMap.grow_factor(0);
    assert(hashMap.grow_factor() == 2);
    hashMap.grow_factor(16);
    assert(hashMap.grow_factor() == 8);
    assert(hashMap.size == 0);
    assert(hashMap.length == 0);
    auto kp = hashMap.keyPointer(1);
    assert(hashMap.size > 0);
    assert(hashMap.length == 0);
    kp.set(1);
    assert(hashMap.length == 1);
    foreach(i;1..16) hashMap[i]=i;
    hashMap.remove(1);
    kp = hashMap.keyPointer(1);
    kp.set(1);
}

// test unsafe types
unittest {
    import std.variant;
    import std.stdio;
    import std.algorithm;

    alias UnsafeType = Algebraic!(int, string);

    HashMap!(UnsafeType, string) unsafeKeyMap;
    UnsafeType k = "one";
    unsafeKeyMap[k] = "value one";
    assert(k in unsafeKeyMap);
    assert(unsafeKeyMap[k] == "value one");
    k = 1;
    assert(k !in unsafeKeyMap);
    unsafeKeyMap[UnsafeType(2)] = "value two";
    assert(unsafeKeyMap.getOrAdd(k, "value one 2") == "value one 2");
    assert(unsafeKeyMap.get(k, "value one 3") == "value one 2");
    assert(equal(unsafeKeyMap.byKey, unsafeKeyMap.byPair.map!"a.key"));
    assert(equal(unsafeKeyMap.byValue, unsafeKeyMap.byPair.map!"a.value"));
    unsafeKeyMap.clear;

    HashMap!(int, UnsafeType) unsafeValueMap;
    auto uv1 = UnsafeType("one");
    auto uv2 = UnsafeType(2);
    auto uv3 = UnsafeType("three");
    unsafeValueMap[1] = uv1;
    unsafeValueMap[2] = uv2;
    assert(1 in unsafeValueMap && unsafeValueMap[1] == "one");
    assert(2 in unsafeValueMap && unsafeValueMap[2] == 2);
    assert(unsafeValueMap.getOrAdd(3, uv3) == "three");
    assert(unsafeValueMap.get(3, UnsafeType("3")) == "three");
    assert(equal(unsafeValueMap.byKey, unsafeValueMap.byPair.map!"a.key"));
    assert(equal(unsafeValueMap.byValue, unsafeValueMap.byPair.map!"a.value"));
    unsafeValueMap.clear;
    
}

// issue #4
unittest {
    HashMap!(string, string) foo;
    foo.remove("a");
}

//
// to use HashMap in @safe @nogc code using class as key, class has to implement
// @safe @nogc opEquals, hoHash, this()
//
@safe @nogc unittest
{
    import std.experimental.allocator.mallocator;

    class C
    {
        int s;
        bool opEquals(const C other) const @safe @nogc
        {
            return s == other.s;
        }

        override hash_t toHash() const @safe @nogc
        {
            return hash_function(s);
        }

        this(int i) @safe @nogc
        {
            s = i;
        }
    }

    int i;
    HashMap!(C, string) map;
    auto allocator = Mallocator.instance;

    auto c0 = () @trusted {return make!C(allocator, ++i);}();
    auto c1 = () @trusted {return make!C(allocator, ++i);}();
    auto c2 = () @trusted {return make!C(allocator, ++i);}();
    map[c0] = "c0";
    map[c1] = "c1";
    assert(c0 in map && c1 in map);
    assert(map.get(c0, "") == "c0");
    assert(map.get(c1, "") == "c1");
    assert(map.getOrAdd(c2, "c2 added") == "c2 added");
    assert(map.length == 3);
}
//
// You can use immutable class instances as key when opEquals and toHash are const.
//
@safe @nogc unittest
{
    import std.experimental.allocator.mallocator;

    class C
    {
        int s;
        bool opEquals(const C other) const @safe @nogc
        {
            return s == other.s;
        }

        override hash_t toHash() const @safe @nogc
        {
            return hash_function(s);
        }

        this(int i) @safe @nogc
        {
            s = i;
        }
    }

    int i;
    alias T = immutable C;
    HashMap!(T, string) map;
    auto allocator = Mallocator.instance;

    auto c0 = () @trusted { return make!T(allocator, ++i); }();
    auto c1 = () @trusted { return make!T(allocator, ++i); }();
    auto c2 = () @trusted { return make!T(allocator, ++i); }();
    map[c0] = "c0";
    map[c1] = "c1";
    assert(c0 in map && c1 in map);
    assert(map.get(c0, "") == "c0");
    assert(map.get(c1, "") == "c1");
    assert(map.getOrAdd(c2, "c2 added") == "c2 added");
    assert(map.length == 3);
}
//
// Nothing special required when using class as value
//
@safe @nogc unittest
{
    import std.experimental.allocator.mallocator;

    class C
    {
        int s;
        this(int i) @safe @nogc
        {
            s = i;
        }
    }

    int i;
    alias T = immutable C;
    HashMap!(string, T) map;
    auto allocator = Mallocator.instance;

    T c0 = () @trusted { return make!T(allocator, ++i); }();
    T c1 = () @trusted { return make!T(allocator, ++i); }();
    T c2 = () @trusted { return make!T(allocator, ++i); }();
    map["c0"] = c0;
    map["c1"] = c1;
    assert("c0" in map && "c1" in map);
    assert(map.get("c0", c2) is c0);
    assert(map.get("c1", c2) is c1);
    assert(map.getOrAdd("c2", c2) is c2);
    map["c2"] = c2;
    assert(map.length == 3);
}
// ditto, with @nogc only
@nogc unittest
{
    import std.experimental.allocator.mallocator;

    static int i;
    class C
    {
        int s;
        bool opEquals(const C other) const @nogc
        {
            return s == other.s;
        }

        override hash_t toHash() const @nogc
        {
            return hash_function(s);
        }

        this() @nogc
        {
            s = ++i;
        }
    }

    HashMap!(C, string) map;
    auto allocator = Mallocator.instance;
    auto c0 = () @trusted { return make!C(allocator); }();
    auto c1 = () @trusted { return make!C(allocator); }();
    auto c2 = () @trusted { return make!C(allocator); }();
    map[c0] = "c0";
    map[c1] = "c1";
    assert(c0 in map && c1 in map);
    assert(map.get(c0, "") == "c0");
    assert(map.get(c1, "") == "c1");
    assert(map.getOrAdd(c2, "c2 added") == "c2 added");
    assert(map.length == 3);
}
// ditto, with @safe only
@safe unittest
{
    import std.experimental.allocator.mallocator;

    static int i;
    class C
    {
        int s;
        bool opEquals(const C other) const @safe
        {
            return s == other.s;
        }

        override hash_t toHash() const @safe
        {
            return hash_function(s);
        }

        this() @safe
        {
            s = ++i;
        }
    }

    HashMap!(C, string) map;
    auto allocator = Mallocator.instance;
    auto c0 = () @trusted { return make!C(allocator); }();
    auto c1 = () @trusted { return make!C(allocator); }();
    auto c2 = () @trusted { return make!C(allocator); }();
    map[c0] = "c0";
    map[c1] = "c1";
    assert(c0 in map && c1 in map);
    assert(map.get(c0, "") == "c0");
    assert(map.get(c1, "") == "c1");
    assert(map.getOrAdd(c2, "c2 added") == "c2 added");
    assert(map.length == 3);
}
