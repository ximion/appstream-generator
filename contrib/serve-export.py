#!/usr/bin/env python3
#
# Copyright (C) 2026 Matthias Klumpp <matthias@tenstral.net>
#
# SPDX-License-Identifier: LGPL-3.0-or-later
#
"""Serve a workspace's export directory locally, to look at the generated pages.

The generated HTML refers to itself through the absolute ``HtmlBaseUrl`` and
``MediaBaseUrl`` from the workspace configuration, which usually point at the machine the
data is published on - so simply opening the files in a browser leaves every stylesheet,
icon and chart broken. This script serves the export directory and rewrites those two URLs
to itself as it hands out pages, so the result behaves like the deployed site.

Usage:
    contrib/serve-export.py [-w WORKSPACE] [-p PORT]
"""

import argparse
import functools
import http.server
import io
import json
import os
import re
import socketserver
import sys
import urllib.parse
import webbrowser
from pathlib import Path

try:
    import yaml

    PARSE_ERRORS: tuple = (ValueError, yaml.YAMLError)
except ImportError:
    # only needed to read YAML configurations, JSON ones work without it
    yaml = None
    PARSE_ERRORS = (ValueError,)

# Extensions the stock mimetypes database gets wrong or does not know about. Note that the
# compressed files are deliberately *not* served with a "Content-Encoding: gzip" header:
# they are downloads in their own right, and the report pages know how to unpack the
# statistics themselves - which is also how the real deployments serve them.
EXTRA_TYPES = {
    ".gz": "application/gzip",
    ".xz": "application/x-xz",
    ".yml": "text/yaml; charset=utf-8",
    ".jxl": "image/jxl",
    ".avif": "image/avif",
    ".webp": "image/webp",
}


# The names the generator itself looks for, in the order it tries them.
CONFIG_NAMES = ("asgen-config.json", "asgen-config.yaml", "asgen-config.yml")


def load_config(workspace: Path) -> dict:
    config_file = next((workspace / name for name in CONFIG_NAMES if (workspace / name).is_file()), None)
    if config_file is None:
        sys.exit(f"No asgen-config.{{json,yaml}} found in {workspace} - is that a workspace?")

    try:
        data = config_file.read_text(encoding="utf-8")
    except OSError as e:
        sys.exit(f"Unable to read {config_file}: {e}")

    # JSON is a subset of YAML, so the generator parses both with its YAML parser and we do
    # the same - but PyYAML may not be installed, and JSON configurations must work anyway.
    try:
        if yaml is not None:
            conf = yaml.safe_load(data)
        elif config_file.suffix == ".json":
            conf = json.loads(data)
        else:
            sys.exit(f"Unable to read {config_file}: PyYAML is required to read YAML configurations.")
    except PARSE_ERRORS as e:
        sys.exit(f"Unable to read {config_file}: {e}")

    if not isinstance(conf, dict):
        sys.exit(f"Unable to read {config_file}: the configuration is not a key/value mapping.")
    return conf


def resolve_export_dir(workspace: Path, conf: dict, key: str, default: str) -> Path:
    """Resolve one of the configured export directories the way the generator does."""
    value = conf.get("ExportDirs", {}).get(key, default)
    path = Path(value)
    if not path.is_absolute():
        path = workspace / "export" / path
    return path.resolve()


class RewritingHandler(http.server.SimpleHTTPRequestHandler):
    """Serves the export tree, pointing the pages' absolute base URLs back at us."""

    # set by serve()
    rewrites: list = []

    def guess_type(self, path):
        suffix = Path(path).suffix.lower()
        if suffix in EXTRA_TYPES:
            return EXTRA_TYPES[suffix]
        return super().guess_type(path)

    def send_head(self):
        path = Path(self.translate_path(self.path))

        # A link like "../" asks for a directory. The base class knows how to turn that
        # into its index.html, but it would then serve the file without our rewriting, so
        # resolve it here instead and let the rewriting path below pick it up.
        if path.is_dir():
            if not urllib.parse.urlsplit(self.path).path.endswith("/"):
                # hand the redirect to the trailing-slash form back to the base class
                return super().send_head()
            index = path / "index.html" if (path / "index.html").is_file() else None
            if index is None:
                # no index page: fall back to the directory listing
                return super().send_head()
            path = index

        if path.suffix.lower() != ".html" or not path.is_file():
            return super().send_head()

        try:
            body = path.read_bytes()
        except OSError:
            self.send_error(404, "File not found")
            return None

        for pattern, replacement in self.rewrites:
            body = pattern.sub(replacement, body)

        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()

        return io.BytesIO(body)

    def end_headers(self):
        # never let the browser hold on to a previous version of a page or a stylesheet
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def log_message(self, fmt, *args):
        if self.path.endswith((".css", ".js", ".png", ".jxl", ".webp", ".svg")):
            return
        super().log_message(fmt, *args)


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def serve(workspace: Path, port: int, open_browser: bool) -> None:
    conf = load_config(workspace)

    html_dir = resolve_export_dir(workspace, conf, "Html", "html")
    media_dir = resolve_export_dir(workspace, conf, "Media", "media")
    if not html_dir.is_dir():
        sys.exit(f"No generated HTML found at {html_dir} - run the generator first.")

    # Serve the common parent of both trees, so that pages and the media they reference are
    # reachable under one origin.
    root = Path(os.path.commonpath([html_dir, media_dir])) if media_dir.is_dir() else html_dir
    base = f"http://localhost:{port}"

    def url_for(path: Path) -> str:
        rel = path.relative_to(root).as_posix()
        return base if rel == "." else f"{base}/{rel}"

    rewrites = []
    for key, path in (("HtmlBaseUrl", html_dir), ("MediaBaseUrl", media_dir)):
        configured = conf.get(key)
        if not configured:
            continue
        configured = configured.rstrip("/")
        rewrites.append((re.compile(re.escape(configured).encode()), url_for(path).encode()))
        print(f"  {key}: {configured}  ->  {url_for(path)}")

    RewritingHandler.rewrites = rewrites
    handler = functools.partial(RewritingHandler, directory=str(root))

    index = url_for(html_dir)
    print(f"\nServing {root}")
    print(f"Report pages: {index}")
    print("Press Ctrl+C to stop.\n")

    if open_browser:
        webbrowser.open(index)

    with Server(("127.0.0.1", port), handler) as httpd:
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\nBye.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument(
        "-w",
        "--workspace",
        default=".",
        help="the generator workspace to serve (default: the current directory)",
    )
    parser.add_argument("-p", "--port", type=int, default=8080, help="port to listen on (default: 8080)")
    parser.add_argument("--open", action="store_true", help="open the report pages in a browser")
    args = parser.parse_args()

    serve(Path(args.workspace).resolve(), args.port, args.open)


if __name__ == "__main__":
    main()
