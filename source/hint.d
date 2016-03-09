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

module ag.hint;

import std.stdio;
import std.string;
import dyaml.all;

alias HintList = GeneratorHint[];

class GeneratorHint
{

private:
    string tag;
    string cid;

    string[string] vars;

public:

    this (string tag, string cid = null)
    {
        this.tag = tag;
        this.cid = cid;
    }

    void setVars (string[string] vars)
    {
        this.vars = vars;

    }

    auto toYamlNode ()
    {
        Node[string] map;

        map["tag"] = Node (tag);
        map["vars"] = Node (vars);

        return Node (map);
    }
}

unittest
{
    import std.stream;
    writeln ("TEST: ", "GeneratorHint");

    auto hint = new GeneratorHint ("just-a-unittest", "org.freedesktop.foobar.desktop");
    hint.vars = ["rainbows": "yes", "unicorns": "no", "storage": "towel"];
    auto root = hint.toYamlNode ();

    auto stream = new MemoryStream ();
    auto dumper = Dumper (stream);
    dumper.indent = 4;
    dumper.explicitStart (true);
    dumper.dump(root);

    writeln (stream.toString ());
}
