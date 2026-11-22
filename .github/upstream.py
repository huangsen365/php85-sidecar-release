#!/usr/bin/env python3
"""Prints the newest PHP 8.5 version in the package repository the image is built from.

The repository is the MIRROR of the Dockerfile, so the answer is what a build would get today, not what php.net
announced: a mirror can be a day behind. Used by .github/workflows/release.yml to decide whether a release is due.
Reads repomd.xml, then the primary package list it names. Standard library only.
"""
import bz2
import gzip
import io
import lzma
import pathlib
import re
import sys
import urllib.request
import xml.etree.ElementTree as ET

PACKAGE = "php85-php-common"
REPO_PATH = "/remi/enterprise/9/safe/x86_64"
REPO_NS = {"r": "http://linux.duke.edu/metadata/repo"}
COMMON = "{http://linux.duke.edu/metadata/common}"


def fetch(url):
    request = urllib.request.Request(url, headers={"User-Agent": "php85-sidecar release check"})
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read()


def unpack(name, raw):
    for suffix, opener in ((".bz2", bz2.decompress), (".gz", gzip.decompress), (".xz", lzma.decompress)):
        if name.endswith(suffix):
            return opener(raw)
    if name.endswith(".xml"):
        return raw
    sys.exit(f"package list in a format this script cannot read: {name}")


def main():
    dockerfile = pathlib.Path(__file__).resolve().parent.parent / "Dockerfile"
    mirror = re.search(r"^ARG MIRROR=(\S+)", dockerfile.read_text(), re.M)
    if not mirror:
        sys.exit("the Dockerfile has no ARG MIRROR line")
    repo = mirror.group(1).rstrip("/") + REPO_PATH
    index = ET.fromstring(fetch(repo + "/repodata/repomd.xml"))
    primary = [d.find("r:location", REPO_NS).get("href") for d in index.findall("r:data", REPO_NS)
               if d.get("type") == "primary"]
    if not primary:
        sys.exit(f"no package list in {repo}")
    versions = []
    for _, node in ET.iterparse(io.BytesIO(unpack(primary[0], fetch(repo + "/" + primary[0])))):
        if node.tag == COMMON + "package":
            if node.findtext(COMMON + "name") == PACKAGE:
                versions.append(node.find(COMMON + "version").get("ver"))
            node.clear()
    if not versions:
        sys.exit(f"{PACKAGE} is not in {repo}")
    print(max(versions, key=lambda v: tuple(int(n) for n in re.findall(r"\d+", v))))


if __name__ == "__main__":
    main()
