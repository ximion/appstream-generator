/*
 * Copyright (C) 2016-2020 Matthias Klumpp <matthias@tenstral.net>
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
@safe:

import std.stdio;
import std.string;
import std.json;
import std.conv : to;

import appstream.Validator : Validator;
import appstream.c.types : IssueSeverity;
import ascompose.Hint : Hint;

import asgen.logging;
import asgen.utils;
import asgen.bindings.asutils : severityFromString, severityToString;


/**
 * Severity assigned with an issue hint.

 * ERROR:   A fatal error which resulted in the component being excluded from the final metadata.
 * WARNING: An issue which did not prevent generating meaningful data, but which is still serious
 *          and should be fixed (warning of this kind usually result in less data).
 * INFO:    Information, no immediate action needed (but will likely be an issue later).
 * PEDANTIC: Information which may improve the data, but could also be ignored.
 */

/**
 * Singleton holding information about the hint tags we know about.
 **/
final class HintTagRegistry
{
    // Thread local
    private static bool instantiated_;

    // Thread global
    private __gshared HintTagRegistry instance_;

    @trusted
    static HintTagRegistry get()
    {
        if (!instantiated_) {
            synchronized (HintTagRegistry.classinfo) {
                if (!instance_)
                    instance_ = new HintTagRegistry ();

                instantiated_ = true;
            }
        }

        return instance_;
    }

    struct HintDefinition
    {
        string tag;
        string text;
        IssueSeverity severity;
        bool internal;
        bool valid;
    }

    private HintDefinition[string] hintDefs;

    private this () @trusted
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

        foreach (ref tag; hintDefsJSON.object.byKey) {
            auto j = hintDefsJSON[tag];
            HintDefinition hdef;

            hdef.tag = tag;
            hdef.severity = severityFromString (j["severity"].str);

            if (j["text"].type == JSONType.array) {
                foreach (l; j["text"].array)
                    hdef.text ~= l.str ~ "\n";
            } else {
                hdef.text = j["text"].str;
            }

            if ("internal" in j)
                hdef.internal = j["internal"].type == JSONType.true_;
            hdef.valid = true;

            hintDefs[tag] = hdef;
        }

        // add AppStream validator hint tags to the registry
        auto validator = new Validator;
        foreach (ref tag; validator.getTags)
            addHintDefForValidatorTag (validator, tag);
    }

    @trusted
    void saveToFile (string fname)
    {
        // is this really the only way you can set a type for JSONValue?
        auto map = JSONValue (["null": 0]);
        map.object.remove ("null");

        foreach (hdef; hintDefs.byValue) {

            auto jval = JSONValue (["text": JSONValue (hdef.text),
                                    "severity": JSONValue (severityToString (hdef.severity))]);
            if (hdef.internal)
                jval.object["internal"] = JSONValue (true);
            map.object[hdef.tag] = jval;
        }

        File file = File(fname, "w");
        file.writeln (map.toJSON (true));
        file.close ();
    }

    private auto addHintDefForValidatorTag (Validator validator, const string tag) @trusted
    {
        import appstream.Validator : IssueSeverity;
        HintDefinition hdef;
        hdef.valid = false;

        immutable asgenTag = "asv-" ~ tag;
        immutable explanation = validator.getTagExplanation (tag);
        if (explanation.empty)
            return hdef;
        immutable asSeverity = validator.getTagSeverity (tag);

        // Translate an AppStream validator hint severity to a generator
        // severity. An error is just a warning here for now, as any error yields
        // to an instant reject of the component (and as long as we extrcated *some*
        // data, that seems a bit harsh)
        IssueSeverity severity;
        switch (asSeverity) {
            case IssueSeverity.ERROR:
                severity = IssueSeverity.WARNING;
                break;
            case IssueSeverity.WARNING:
                severity = IssueSeverity.WARNING;
                break;
            case IssueSeverity.INFO:
                severity = IssueSeverity.INFO;
                break;
            case IssueSeverity.PEDANTIC:
                severity = IssueSeverity.PEDANTIC;
                break;
            default:
                severity = IssueSeverity.UNKNOWN;
        }

        hdef.tag = asgenTag;
        hdef.severity = severity;
        hdef.text = "<code>{{location}}</code> - <em>{{hint}}</em><br/>%s".format (escapeXml (explanation));
        hdef.valid = true;

        hintDefs[asgenTag] = hdef;

        return hdef;
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
    IssueSeverity getSeverity (string tag) pure
    {
        auto hDef = getHintDef (tag);
        return hDef.severity;
    }
}

public Hint createHint (const string tag, const string cid) @trusted
{
    auto h = new Hint;
    h.setTag (tag);

    const severity = HintTagRegistry.get.getSeverity (tag);
    if (severity == IssueSeverity.UNKNOWN)
        logWarning ("Severity of hint tag '%s' is unknown. This likely means that this tag is not registered and should not be emitted.", tag);
    h.setSeverity (severity);

    return h;
}

public auto toJsonValue (Hint hint) @trusted
{
    auto hintList = hint.getExplanationVarsList;
    string[string] vars;
    for (uint i = 0; i < hintList.len; i++) {
        if (i % 2 != 0)
            continue;
        const auto key = fromStringz (cast(char*) hintList.index (i)).to!string;
        const auto value = fromStringz (cast(char*) hintList.index (i + 1)).to!string;
        vars[key] = value;
    }

    return JSONValue(["tag":  JSONValue (hint.getTag),
                      "vars": JSONValue (vars)]);
}

@trusted
unittest
{
    writeln ("TEST: ", "Issue Hints");

    auto hint = createHint ("just-a-unittest", "org.freedesktop.foobar.desktop");
    foreach (k, v; ["rainbows": "yes", "unicorns": "no", "storage": "towel"])
        hint.addExplanationVar (k, v);
    auto root = hint.toJsonValue ();

    writeln (root.toJSON (true));

    auto registry = HintTagRegistry.get ();
    registry.getHintDef ("asv-relation-item-invalid-vercmp");
    registry.saveToFile ("/tmp/testsuite-asgen-hints.json");
}
