/*
* Copyright: Copyright Sean Kelly 2009 - 2014.
* License:   <a href="http://www.boost.org/LICENSE_1_0.txt">Boost License 1.0</a>.
* Authors:   Sean Kelly, Alex Rønne Petersen, Martin Nowak
* Source:    $(PHOBOSSRC std/_concurrency.d)
*/
/*          Copyright Sean Kelly 2009 - 2014.
* Distributed under the Boost Software License, Version 1.0.
*    (See accompanying file LICENSE_1_0.txt or copy at
*          http://www.boost.org/LICENSE_1_0.txt)
*/

module ag.std.concurrency.generator;

import std.concurrency;
import core.thread;

class Generator(T) :
    Fiber
{
    /**
     * Initializes a generator object which is associated with a static
     * D function.  The function will be called once to prepare the range
     * for iteration.
     *
     * Params:
     *  fn = The fiber function.
     *
     * In:
     *  fn must not be null.
     */
    this(void function() fn)
    {
        super(fn);
        call();
    }


    /**
     * Initializes a generator object which is associated with a static
     * D function.  The function will be called once to prepare the range
     * for iteration.
     *
     * Params:
     *  fn = The fiber function.
     *  sz = The stack size for this fiber.
     *
     * In:
     *  fn must not be null.
     */
    this(void function() fn, size_t sz)
    {
        super(fn, sz);
        call();
    }


    /**
     * Initializes a generator object which is associated with a dynamic
     * D function.  The function will be called once to prepare the range
     * for iteration.
     *
     * Params:
     *  dg = The fiber function.
     *
     * In:
     *  dg must not be null.
     */
    this(void delegate() dg)
    {
        super(dg);
        call();
    }


    /**
     * Initializes a generator object which is associated with a dynamic
     * D function.  The function will be called once to prepare the range
     * for iteration.
     *
     * Params:
     *  dg = The fiber function.
     *  sz = The stack size for this fiber.
     *
     * In:
     *  dg must not be null.
     */
    this(void delegate() dg, size_t sz)
    {
        super(dg, sz);
        call();
    }


    /**
     * Returns true if the generator is empty.
     */
    final bool empty() @property
    {
        return m_value is null || state == State.TERM;
    }


    /**
     * Obtains the next value from the underlying function.
     */
    final void popFront()
    {
        call();
    }


    /**
     * Returns the most recently generated value.
     */
    final T front() @property
    {
        return *m_value;
    }


private:
    T*  m_value;
}

/**
 * Yields a value of type T to the caller of the currently executing
 * generator.
 *
 * Params:
 *  value = The value to yield.
 */
void yield(T)(ref T value)
{
    Generator!T cur = cast(Generator!T) Fiber.getThis();
    if (cur !is null && cur.state == Fiber.State.EXEC)
    {
        cur.m_value = &value;
        return Fiber.yield();
    }
    throw new Exception("yield(T) called with no active generator for the supplied type");
}


/// ditto
void yield(T)(T value)
{
    yield(value);
}
