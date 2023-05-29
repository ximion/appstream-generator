/*
 * Copyright (C) 2021-2022 Matthias Klumpp <matthias@tenstral.net>
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

module asgen.cptmodifiers;

import core.sync.rwmutex : ReadWriteMutex;
import std.json : parseJSON;
import std.stdio : File;
import std.path : buildPath;
import std.typecons : Nullable;
static import std.file;

import appstream.Component : Component, ComponentKind, MergeKind;

import asgen.logging;
import asgen.config : Suite;
import asgen.result : GeneratorResult;

/**
 * Helper class to provide information about repository-specific metadata modifications.
 * Instances of this class must be thread safe.
 */
class InjectedModifications {
private:
    Component[string] m_removedComponents;
    string[string][string] m_injectedCustomData;

    bool m_hasRemovedCpts;
    bool m_hasInjectedCustom;

    ReadWriteMutex m_mutex;

public:
    this ()
    {
        m_mutex = new ReadWriteMutex;
    }

    void loadForSuite (Suite suite)
    {
        synchronized (m_mutex.writer) {
            m_removedComponents.clear();
            m_injectedCustomData.clear();

            immutable fname = buildPath(suite.extraMetainfoDir, "modifications.json");
            if (!std.file.exists(fname))
                return;
            logInfo("Using repo-level modifications for %s (via modifications.json)", suite.name);

            auto f = File(fname, "r");
            string jsonData;
            string line;
            while ((line = f.readln()) !is null)
                jsonData ~= line;

            auto jroot = parseJSON(jsonData);

            if ("InjectCustom" in jroot) {
                logDebug("Using injected custom entries from %s", fname);
                auto jInjCustom = jroot["InjectCustom"].object;
                foreach (ref jEntry; jInjCustom.byKeyValue) {
                    string[string] kv;
                    foreach (ref jCustom; jEntry.value.object.byKeyValue)
                        kv[jCustom.key] = jCustom.value.str;
                    m_injectedCustomData[jEntry.key] = kv;
                }
            }

            if ("Remove" in jroot) {
                logDebug("Using package removal info from %s", fname);
                foreach (jCid; jroot["Remove"].array) {
                    immutable cid = jCid.str;

                    auto cpt = new Component;
                    cpt.setKind(ComponentKind.GENERIC);
                    cpt.setMergeKind(MergeKind.REMOVE_COMPONENT);
                    cpt.setId(cid);

                    m_removedComponents[cid] = cpt;
                }
            }

            m_hasRemovedCpts = m_removedComponents.length != 0;
            m_hasInjectedCustom = m_injectedCustomData.length != 0;
        }
    }

    @property
    bool hasRemovedComponents ()
    {
        return m_hasRemovedCpts;
    }

    /**
     * Test if component was marked for deletion.
     */
    bool isComponentRemoved (const string cid)
    {
        if (!m_hasRemovedCpts)
            return false;
        synchronized (m_mutex.reader)
            return (cid in m_removedComponents) !is null;
    }

    /**
     * Get injected custom data entries.
     */
    Nullable!(string[string]) injectedCustomData (const string cid)
    {
        Nullable!(string[string]) result;
        if (!m_hasInjectedCustom)
            return result;
        synchronized (m_mutex.reader) {
            auto injCustomP = cid in m_injectedCustomData;
            if (injCustomP is null)
                return result;
            result = *injCustomP;
            return result;
        }
    }

    void addRemovalRequestsToResult (GeneratorResult gres)
    {
        synchronized (m_mutex.reader) {
            foreach (cpt; m_removedComponents.byValue)
                gres.addComponentWithString(cpt, gres.pkid ~ "/-" ~ cpt.getId);
        }
    }

}

unittest {
    import std.stdio : writeln;
    import asgen.utils : getTestSamplesDir;

    writeln("TEST: ", "InjectedModifications");

    Suite dummySuite;
    dummySuite.name = "dummy";
    dummySuite.extraMetainfoDir = buildPath(getTestSamplesDir(), "extra-metainfo");

    auto injMods = new InjectedModifications;
    injMods.loadForSuite(dummySuite);

    assert(injMods.isComponentRemoved("com.example.removed"));
    assert(!injMods.isComponentRemoved("com.example.not_removed"));

    assert(injMods.injectedCustomData("org.example.nodata").isNull);
    assert(injMods.injectedCustomData("org.example.newdata") == [
        "earth": "moon",
        "mars": "phobos",
        "saturn": "thrym"
    ]);
}
