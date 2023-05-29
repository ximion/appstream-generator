/*
 * Copyright (C) 2016 Matthias Klumpp <matthias@tenstral.net>
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

module asgen.backends.archlinux.listfile;

import std.stdio;
import std.string;

final class ListFile {

private:
    string[string] entries;

public:

    this ()
    {
    }

    void loadData (const(ubyte)[] data)
    {
        string[] content;
        auto dataStr = cast(string) data;
        content = dataStr.splitLines();

        string blockName = null;
        foreach (l; content) {
            if ((l.startsWith("%")) && (l.endsWith("%"))) {
                blockName = l[1 .. $ - 1];
                continue;
            }

            if (l == "") {
                blockName = null;
                continue;
            }

            if (blockName !is null) {
                if (blockName in entries)
                    entries[blockName] ~= "\n" ~ l;
                else
                    entries[blockName] = l;
                continue;
            }
        }
    }

    string getEntry (string name)
    {
        auto resP = name in entries;

        if (resP is null) // we found nothing
            return null;
        return *resP;
    }
}

unittest {
    writeln("TEST: ", "Backend::Archlinux - ListFile");

    string data = "%FILENAME%
a2ps-4.14-6-x86_64.pkg.tar.xz

%NAME%
a2ps

%VERSION%
4.14-6

%DESC%
An Any to PostScript filter

%CSIZE%
629320

%MULTILINE%
Blah1
BLUBB2
EtcEtcEtc3

%SHA256SUM%
a629a0e0eca0d96a97eb3564f01be495772439df6350600c93120f5ac7f3a1b5";

    auto lf = new ListFile();
    lf.loadData(cast(ubyte[]) data);

    assert(lf.getEntry("FILENAME") == "a2ps-4.14-6-x86_64.pkg.tar.xz");
    assert(lf.getEntry("VERSION") == "4.14-6");
    assert(lf.getEntry("MULTILINE") == "Blah1\nBLUBB2\nEtcEtcEtc3");
    assert(lf.getEntry("SHA256SUM") == "a629a0e0eca0d96a97eb3564f01be495772439df6350600c93120f5ac7f3a1b5");
}
