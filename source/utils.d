/*
 * Copyright (C) 2016 Matthias Klumpp <matthias@tenstral.net>
 *
 * Licensed under the GNU Lesser General Public License Version 3
 *
 * This library is free software: you can redistribute it and/or modify
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
 * along with this library.  If not, see <http://www.gnu.org/licenses/>.
 */

module ag.utils;

import std.ascii : letters, digits;
import std.conv : to;
import std.random : randomSample;
import std.range : chain;
import std.string;


private __gshared string agTmpDir_;

/**
 * Generate a random alphanumeric string.
 */
string randomString (uint len)
{
    auto asciiLetters = to! (dchar[]) (letters);
    auto asciiDigits = to! (dchar[]) (digits);

    if (len == 0)
        len = 1;

    auto res = to!string (randomSample (chain (asciiLetters, asciiDigits), len));
    return res;
}

/**
 * Get unique temporary directory to use during one generator run.
 */
string getAgTmpDir ()
{
    import std.file;
    import std.path;

    if (!agTmpDir_) {
        // TODO: Make theadsafe
        agTmpDir_ = buildPath (tempDir (), format ("asgen-%s", randomString (8)));
        mkdirRecurse (agTmpDir_);
    }

    return agTmpDir_;
}
