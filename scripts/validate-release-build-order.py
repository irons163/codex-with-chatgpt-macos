#!/usr/bin/env python3
"""Reject Sparkle build numbers that do not advance existing update feeds."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path
import re
from urllib.parse import unquote, urlparse
import xml.etree.ElementTree as ElementTree


SPARKLE_NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
VERSION_ATTRIBUTE = f"{{{SPARKLE_NAMESPACE}}}version"
SHORT_VERSION_ATTRIBUTE = f"{{{SPARKLE_NAMESPACE}}}shortVersionString"
RELEASE_TAG_PATTERN = re.compile(r"/releases/download/([^/]+)/")


@dataclass(frozen=True)
class ExistingRelease:
    build: int
    short_version: str
    tag: str
    source: Path


def fail(message: str) -> None:
    raise SystemExit(f"validate-release-build-order: {message}")


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--appcast-directory", type=Path, required=True)
    parser.add_argument("--current-build", required=True)
    parser.add_argument("--current-version", required=True)
    parser.add_argument("--current-tag", required=True)
    return parser.parse_args()


def release_tag_from_url(url: str, source: Path) -> str:
    match = RELEASE_TAG_PATTERN.search(urlparse(url).path)
    if match is None:
        fail(f"{source} has an enclosure URL without a GitHub release tag")
    return unquote(match.group(1))


def load_existing_releases(directory: Path) -> list[ExistingRelease]:
    if not directory.is_dir():
        fail(f"appcast directory does not exist: {directory}")
    releases: list[ExistingRelease] = []
    for source in sorted(directory.glob("*.xml")):
        try:
            root = ElementTree.parse(source).getroot()
        except (ElementTree.ParseError, OSError) as error:
            fail(f"cannot parse {source}: {error}")
        enclosures = root.findall(".//enclosure")
        if not enclosures:
            fail(f"{source} does not contain an enclosure")
        for enclosure in enclosures:
            build_text = enclosure.get(VERSION_ATTRIBUTE, "")
            short_version = enclosure.get(SHORT_VERSION_ATTRIBUTE, "")
            url = enclosure.get("url", "")
            if not build_text.isdigit():
                fail(f"{source} has a non-integer sparkle:version")
            if not short_version or not url:
                fail(f"{source} has incomplete version metadata")
            releases.append(ExistingRelease(
                build=int(build_text),
                short_version=short_version,
                tag=release_tag_from_url(url, source),
                source=source,
            ))
    return releases


def main() -> None:
    arguments = parse_arguments()
    if not arguments.current_build.isdigit():
        fail("--current-build must be an unsigned integer")
    current_build = int(arguments.current_build)
    releases = load_existing_releases(arguments.appcast_directory)
    if not releases:
        print("No existing appcast build numbers were found; first release is allowed.")
        return
    maximum = max(release.build for release in releases)
    if current_build > maximum:
        print(f"Build {current_build} advances the existing maximum build {maximum}.")
        return
    if current_build < maximum:
        fail(f"build {current_build} must be greater than existing build {maximum}")
    conflicts = [
        release for release in releases
        if release.build == maximum
        and (release.short_version != arguments.current_version
             or release.tag != arguments.current_tag)
    ]
    if conflicts:
        conflict = conflicts[0]
        fail(
            f"build {current_build} is already used by {conflict.short_version} "
            f"({conflict.tag}) in {conflict.source}"
        )
    print(f"Build {current_build} already belongs to {arguments.current_tag}; rerun allowed.")


if __name__ == "__main__":
    main()
