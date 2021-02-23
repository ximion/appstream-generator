/*
 * Copyright (C) 2016-2018 Matthias Klumpp <matthias@tenstral.net>
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

module asgen.backends.debian.tagfile;

import std.stdio : File;
import std.string : startsWith, indexOf, chompPrefix, strip, split, splitLines;
import std.typecons : Flag, Yes;
import std.array : appender, empty;
import std.conv : to;
import std.path : buildPath;

import asgen.zarchive;
import asgen.logging;


/**
 * Parser for Debian's RFC2822-style metadata.
 */
final class TagFile
{

private:
    string[] content;
    uint pos;
    string[string] currentBlock;

    string _fname;

public:

    this () @trusted
    {
        currentBlock.clear ();
    }

    void open (string fname, Flag!"compressed" compressed = Yes.compressed) @trusted
    {
        _fname = fname;

        if (compressed) {
            auto data = decompressFile (fname);
            load (data);
        } else {
            import std.stdio;

            auto f = File (fname, "r");
            auto data = appender!string;
            string line;
            while ((line = f.readln ()) !is null)
                data ~= line;
            load (data.data);
        }
    }

    @property string fname () const { return _fname; }

    void load (string data)
    {
        content = data.splitLines ();
        pos = 0;
        readCurrentBlockData ();
    }

    void first () {
        pos = 0;
    }

    private void readCurrentBlockData () @trusted
    {
        currentBlock.clear ();
        immutable clen = content.length;

        for (auto i = pos; i < clen; i++) {
            if (content[i] == "")
                break;

            // check whether we are in a multiline value field, and just skip forward in that case
            if (startsWith (content[i], " "))
                continue;

            immutable separatorIndex = indexOf (content[i], ':');
            if (separatorIndex <= 0)
                continue; // this is no field

            auto fieldName = content[i][0..separatorIndex];
            auto fdata = content[i][separatorIndex+1..$];

            if ((i+1 >= clen)
                || (!startsWith (content[i+1], " "))) {
                    // we have a single-line field
                    currentBlock[fieldName] = fdata.strip ();
            } else {
                // we have a multi-line field
                auto fdata_ml = appender!string ();
                fdata_ml ~= fdata.strip ();
                for (auto j = i+1; j < clen; j++) {
                    auto slice = chompPrefix (content[j], " ");
                    if (slice == content[j])
                        break;

                    if (fdata_ml.data == "") {
                        fdata_ml = appender!string ();
                        fdata_ml ~= slice;
                    } else {
                        fdata_ml ~= "\n";
                        fdata_ml ~= slice;
                    }
                }

                currentBlock[fieldName] = fdata_ml.data;
            }
        }
    }

    bool nextSection () @trusted
    {
        bool breakNext = false;
        immutable clen = content.length;
        currentBlock.clear ();

        if (pos >= clen)
            return false;

        uint i;
        for (i = pos; i < clen; i++) {
            if (content[i] == "") {
                pos = i + 1;
                breakNext = true;
            } else if (breakNext) {
                break;
            }
        }

        // check if we reached the end of this file
        if (i == clen)
            pos = cast(uint) clen;

        if (pos >= clen)
            return false;

        readCurrentBlockData ();
        return true;
    }

    string readField (string name, string defaultValue = null) @trusted
    {
        auto dataP = name in currentBlock;
        if (dataP is null)
            return defaultValue; // we found nothing
        else
            return *dataP;
    }
}
