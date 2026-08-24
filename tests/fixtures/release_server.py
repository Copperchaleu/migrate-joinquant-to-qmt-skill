#!/usr/bin/env python3
"""Serve release fixtures and redirect /releases/latest to an immutable tag."""

import argparse
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer


class ReleaseHandler(SimpleHTTPRequestHandler):
    release_tag = None

    def do_GET(self):
        if self.path == "/releases/latest":
            destination = "/releases/download/{}/".format(self.release_tag)
            self.send_response(302)
            self.send_header("Location", destination)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        super().do_GET()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bind", default="127.0.0.1")
    parser.add_argument("--directory", required=True)
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--tag", required=True)
    args = parser.parse_args()

    ReleaseHandler.release_tag = args.tag
    handler = partial(ReleaseHandler, directory=args.directory)
    server = ThreadingHTTPServer((args.bind, args.port), handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
