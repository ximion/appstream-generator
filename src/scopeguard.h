/*
 * Copyright (C) 2025-2026 Matthias Klumpp <matthias@tenstral.net>
 *
 * Licensed under the GNU Lesser General Public License Version 3
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, either version 3 of the license, or
 * (at your option) any later version.
 *
 * This software is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this software.  If not, see <http://www.gnu.org/licenses/>.
 */

#pragma once

#include <cassert>
#include <type_traits>
#include <utility>

namespace ASGenerator
{

namespace Utils
{

/**
 * Runs a function when it goes out of scope, unless it was dismissed or already committed.
 */
template<typename F>
class ScopeGuard
{
public:
    [[nodiscard]] explicit ScopeGuard(F &&f) noexcept
        : m_func(std::move(f))
    {
    }

    [[nodiscard]] explicit ScopeGuard(const F &f) noexcept
        : m_func(f)
    {
    }

    [[nodiscard]] ScopeGuard(ScopeGuard &&other) noexcept
        : m_func(std::move(other.m_func)),
          m_invoke(std::exchange(other.m_invoke, false))
    {
    }

    ~ScopeGuard() noexcept
    {
        if (m_invoke)
            m_func();
    }

    /**
     * Never run the function.
     */
    void dismiss() noexcept
    {
        m_invoke = false;
    }

    /**
     * Run the function right now instead of at the end of the scope.
     */
    void commit() noexcept(std::is_nothrow_invocable_v<F>)
    {
        assert(m_invoke);
        m_invoke = false; // do it before we may throw from calling m_func()
        m_func();
    }

    ScopeGuard(const ScopeGuard &) = delete;
    ScopeGuard &operator=(const ScopeGuard &) = delete;
    ScopeGuard &operator=(ScopeGuard &&) = delete;

private:
    F m_func;
    bool m_invoke = true;
};

template<typename F>
ScopeGuard(F (&)()) -> ScopeGuard<F (*)()>;

template<typename F>
[[nodiscard]] ScopeGuard<typename std::decay<F>::type> scopeGuard(F &&f)
{
    return ScopeGuard<typename std::decay<F>::type>(std::forward<F>(f));
}

} // namespace Utils
} // namespace ASGenerator
