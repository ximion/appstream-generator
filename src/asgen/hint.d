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

module asgen.hint;

import std.stdio;
import std.string;
import std.json;

import asgen.logging;
import asgen.utils;

alias HintList = GeneratorHint[];

/**
 * Severity assigned with an issue hint.
 *
 * INFO:    Information, no immediate action needed (but will likely be an issue later).
 * WARNING: An issue which did not prevent generating meaningful data, but which is still serious
 *          and should be fixed (warning of this kind usually result in less data).
 * ERROR:   A fatal error which resulted in the component being excluded from the final metadata.
 */
enum HintSeverity
{
    UNKNOWN,
    INFO,
    WARNING,
    ERROR
}

@safe
private HintSeverity severityFromString (string str) pure
{
    switch (str) {
        case "error":
            return HintSeverity.ERROR;
        case "warning":
            return HintSeverity.WARNING;
        case "info":
            return HintSeverity.INFO;
        default:
            return HintSeverity.UNKNOWN;
    }
}

class GeneratorHint
{

private:
    string tag;
    string cid;

    string[string] vars;

    HintSeverity severity;

public:

    @trusted
    this (string tag, string cid = null)
    {
        this.tag = tag;
        this.cid = cid;

        severity = HintsStorage.get ().getSeverity (tag);
        if (severity == HintSeverity.UNKNOWN)
            logWarning ("Severity of hint tag '%s' is unknown. This likely means that this tag is not registered and should not be emitted.", tag);
    }

    @safe
    bool isError () pure
    {
        return severity == HintSeverity.ERROR;
    }

    @safe
    void setVars (string[string] vars) pure
    {
        this.vars = vars;
    }

    @safe
    auto toJsonNode () pure
    {
        JSONValue json = JSONValue(["tag":  JSONValue (tag),
                                    "vars": JSONValue (vars)
                                   ]);
        return json;
    }
}

/**
 * Singleton holding information about the hint tags we know about.
 **/
class HintsStorage
{
    // Thread local
    private static bool instantiated_;

    // Thread global
    private __gshared HintsStorage instance_;

    static HintsStorage get()
    {
        if (!instantiated_) {
            synchronized (HintsStorage.classinfo) {
                if (!instance_)
                    instance_ = new HintsStorage ();

                instantiated_ = true;
            }
        }

        return instance_;
    }

    struct HintDefinition
    {
        string tag;
        string text;
        HintSeverity severity;
        bool internal;
    }

    private HintDefinition[string] hintDefs;

    @trusted
    private this ()
    {
        import std.path;
        static import std.file;

        // find the hint definition file
        auto hintsDefFile = getDataPath ("asgen-hints.json");
        if (!std.file.exists (hintsDefFile)) {
            logError ("Hints definition file '%s' was not found! This means we can not determine severity of issue tags and not render report pages.", hintsDefFile);
            return;
        }

        // read the hints definition JSON file
        auto f = File (hintsDefFile, "r");
        string jsonData;
        string line;
        while ((line = f.readln ()) !is null)
            jsonData ~= line;

        auto hintDefsJSON = parseJSON (jsonData);

        foreach (tag; hintDefsJSON.object.byKey ()) {
            auto j = hintDefsJSON[tag];
            auto def = HintDefinition ();

            def.tag = tag;
            def.severity = severityFromString (j["severity"].str);

            if (j["text"].type == JSON_TYPE.ARRAY) {
                foreach (l; j["text"].array)
                    def.text ~= l.str ~ "\n";
            } else {
                def.text = j["text"].str;
            }

            if ("internal" in j)
                def.internal = j["internal"].type == JSON_TYPE.TRUE;

            hintDefs[tag] = def;
        }
    }

    @safe
    HintDefinition getHintDef (string tag) pure
    {
        auto defP = (tag in hintDefs);
        if (defP is null)
            return HintDefinition ();
        return *defP;
    }

    @safe
    HintSeverity getSeverity (string tag) pure
    {
        auto hDef = getHintDef (tag);
        return hDef.severity;
    }
}

unittest
{
    writeln ("TEST: ", "Issue Hints");

    auto hint = new GeneratorHint ("just-a-unittest", "org.freedesktop.foobar.desktop");
    hint.vars = ["rainbows": "yes", "unicorns": "no", "storage": "towel"];
    auto root = hint.toJsonNode ();

    writeln (toJSON (&root, true));

    HintsStorage.get ();
}
