/*
 * Copyright (C) 2019-2022 Matthias Klumpp <matthias@tenstral.net>
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

module asgen.downloader;
@safe:

import std.stdio : File;
import std.typecons : Nullable;
import std.datetime : SysTime, Clock, parseRFC822DateTime, DateTimeException;
import std.array : appender, empty;
import std.path : buildPath, dirName, buildNormalizedPath;
import std.algorithm : startsWith;
import std.format : format;
import std.conv : to;
import asgen.logging;
static import std.file;

import asgen.config : Config;
import asgen.defines : ASGEN_VERSION;
import asgen.utils : isRemote, randomString;

class DownloadException : Exception
{
    @safe pure nothrow
    this(const string msg,
         const string file = __FILE__,
         size_t line = __LINE__,
         Throwable next = null)
    {
        super (msg, file, line, next);
    }
}

/**
 * Download data via HTTP. Based on cURL.
 */
final class Downloader
{

private:
    immutable string caInfo;
    immutable string userAgent;

    // thread local instance
    static Downloader instance_;

public:

    static Downloader get () @trusted
    {
        if (instance_ is null)
           instance_ = new Downloader;
        return instance_;
    }

    this () @trusted
    {
        userAgent = "appstream-generator/" ~ ASGEN_VERSION;

        // set custom SSL CA file, if we have one
        caInfo = Config.get.caInfo;
    }

    private immutable(Nullable!SysTime) downloadInternal (const string url, ref File dest, const uint maxTryCount = 5) @trusted
    in { assert (url.isRemote); }
    do
    {
        import core.time : dur;
        import std.string : toLower;
        import std.net.curl : HTTP, FTP;
        import std.typecons : Yes;

        Nullable!SysTime ret;

        size_t onReceiveCb (File f, ubyte[] data)
        {
            f.rawWrite (data);
            return data.length;
        }

        /* the curl library is stupid; you can't make an AutoProtocol set timeouts */
        logDebug ("Downloading %s", url);
        try {
            if (url.startsWith ("http")) {
                immutable httpsUrl = url.startsWith ("https");
                auto curlHttp = HTTP (url);
                if (!caInfo.empty)
                    curlHttp.caInfo = caInfo;
                curlHttp.setUserAgent (userAgent);

                HTTP.StatusLine statusLine;
                curlHttp.connectTimeout = dur!"seconds" (30);
                curlHttp.dataTimeout = dur!"seconds" (30);
                curlHttp.onReceive = (data) => onReceiveCb (dest, data);
                curlHttp.onReceiveStatusLine = (HTTP.StatusLine l) { statusLine = l; };
                curlHttp.onReceiveHeader = (in char[] key, in char[] value) {
                    // we will not allow a HTTPS --> HTTP downgrade
                    if (!httpsUrl)
                        return;
                    if (key == "location" && value.toLower.startsWith ("http:"))
                        throw new DownloadException ("HTTPS URL tried to redirect to a less secure HTTP URL.");
                };
                curlHttp.perform(Yes.throwOnError);
                if ("last-modified" in curlHttp.responseHeaders) {
                        auto lastmodified = curlHttp.responseHeaders["last-modified"];
                        ret = parseRFC822DateTime(lastmodified);
                }

                if (statusLine.code != 200 && statusLine.code != 301 && statusLine.code != 302) {
                    if (statusLine.code == 0) {
                        // with some recent update of the D runtime or Curl, the status line isn't set anymore
                        // just to be safe, check whether we received data before assuming everything went fine
                        if (dest.size == 0)
                            throw new DownloadException ("No data was received from the remote end (Code: %d).".format (statusLine.code));
                    } else {
                        throw new DownloadException ("HTTP request returned status code %d (%s)".format (statusLine.code, statusLine.reason));
                    }
                }
            } else {
                auto curlFtp = FTP (url);
                curlFtp.connectTimeout = dur!"seconds" (30);
                curlFtp.dataTimeout = dur!"seconds" (30);
                curlFtp.onReceive = (data) => onReceiveCb (dest, data);
                curlFtp.perform(Yes.throwOnError);
            }
            logDebug ("Downloaded %s", url);
        } catch (Exception e) {
            if (maxTryCount > 0) {
                logDebug ("Failed to download %s, will retry %d more %s",
                        url,
                        maxTryCount,
                        maxTryCount > 1 ? "times" : "time");
                download (url, dest, maxTryCount - 1);
            } else {
                throw new DownloadException (e.message.to!string);
            }
        }

        return ret;
    }

    immutable(Nullable!SysTime) download (const string url, ref File dFile, const uint maxTryCount = 4) @trusted
    {
        return downloadInternal (url, dFile, maxTryCount);
    }

    immutable(ubyte[]) download (const string url, const uint maxTryCount = 4) @trusted
    {
        import core.stdc.stdlib : free;
        import core.sys.posix.stdio : fclose, open_memstream;

        char* ptr = null;
        scope (exit) free (ptr);
        size_t sz = 0;

        {
            auto f = open_memstream (&ptr, &sz);
            scope (exit) fclose (f);
            auto file = File.wrapFile (f);
            downloadInternal (url, file, maxTryCount);
        }

        return cast(immutable ubyte[]) ptr[0..sz].idup;
    }

    /**
     * Download `url` to `dest`.
     *
     * Params:
     *      url = The URL to download.
     *      dest = The location for the downloaded file.
     *      maxTryCount = Number of times to attempt the download.
     */
    void downloadFile (const string url, const string dest, const uint maxTryCount = 4) @trusted
    in  { assert (url.isRemote); }
    out { assert (std.file.exists (dest)); }
    do
    {
        import std.file : exists, mkdirRecurse, setTimes, remove;
        static import std.file;

        if (dest.exists) {
            logDebug ("File '%s' already exists, re-download of '%s' skipped.", dest, url);
            return;
        }

        mkdirRecurse (dest.dirName);

        auto f = File (dest, "wb");
        scope (failure) remove (dest);

        auto time = downloadInternal (url, f, maxTryCount);

        f.close ();
        if (!time.isNull)
            setTimes (dest, Clock.currTime, time.get);
    }

    /**
     * Download `url` and return a string with its contents.
     *
     * Params:
     *      url = The URL to download.
     *      maxTryCount = Number of times to retry on timeout.
     */
    string downloadText (const string url, const uint maxTryCount = 4) @trusted
    {
        const data = download (url, maxTryCount);
        return (cast(char[])data).to!string;
    }

    /**
     * Download `url` and return a string array of lines.
     *
     * Params:
     *      url = The URL to download.
     *      maxTryCount = Number of times to retry on timeout.
     */
    string[] downloadTextLines (const string url, const uint maxTryCount = 4) @trusted
    {
        import std.string : splitLines;
        return downloadText (url, maxTryCount).splitLines;
    }

}

@trusted
unittest
{
    import std.stdio : writeln;
    import std.exception : assertThrown;
    import std.file : remove, readText;
    import std.process : environment;
    asgen.logging.setVerbose (true);

    writeln ("TEST: ", "Downloader");

    if (environment.get("ASGEN_TESTS_NO_NET", "no") != "no") {
        writeln ("I: NETWORK DEPENDENT TESTS SKIPPED. (explicitly disabled via `ASGEN_TESTS_NO_NET`)");
        return;
    }

    immutable urlFirefoxDetectportal = "https://detectportal.firefox.com/";
    auto dl = new Downloader;
    string detectPortalRes;
    try {
        detectPortalRes = dl.downloadText (urlFirefoxDetectportal);
    } catch (DownloadException e) {
        writeln ("W: NETWORK DEPENDENT TESTS SKIPPED. (automatically, no network detected: ", e.msg, ")");
        return;
    }
    writeln ("I: Running network-dependent tests.");
    assert (detectPortalRes == "success\n");

    // check if a downloaded file contains the right contents
    immutable firefoxDetectportalFname = "/tmp/asgen-test.ffdp" ~ randomString (4);
    scope(exit) firefoxDetectportalFname.remove ();
    dl.downloadFile (urlFirefoxDetectportal, firefoxDetectportalFname);
    assert (readText (firefoxDetectportalFname) == "success\n");


    // download a bigger chunk of data without error
    immutable debianOrgFname = "/tmp/asgen-test.do" ~ randomString (4);
    scope(exit) debianOrgFname.remove ();
    dl.downloadFile ("https://debian.org", debianOrgFname);

    // fail when attempting to download a nonexistent file
    assertThrown!DownloadException (dl.downloadFile ("https://appstream.debian.org/nonexistent", "/tmp/asgen-dltest" ~ randomString (4), 2));

    // check if HTTP --> HTTPS redirects, like done on mozilla.org, work
    dl.downloadFile ("http://mozilla.org", "/tmp/asgen-test.mozilla" ~ randomString (4), 1);
}
