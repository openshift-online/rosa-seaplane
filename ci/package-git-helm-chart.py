#!/usr/bin/env python3
"""Build a deterministic Helm chart archive from a git-archive tar stream."""

from __future__ import annotations

import gzip
import sys
import tarfile
from pathlib import Path


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: package-git-helm-chart.py SOURCE.tar OUTPUT.tgz")

    source_path = Path(sys.argv[1])
    output_path = Path(sys.argv[2])
    output_path.parent.mkdir(parents=True, exist_ok=True)

    with tarfile.open(source_path, mode="r:") as source:
        members = sorted(source.getmembers(), key=lambda member: member.name)
        with output_path.open("wb") as raw_output:
            with gzip.GzipFile(fileobj=raw_output, mode="wb", mtime=0) as compressed:
                with tarfile.open(
                    fileobj=compressed,
                    mode="w",
                    format=tarfile.PAX_FORMAT,
                ) as output:
                    for member in members:
                        normalized = tarfile.TarInfo(member.name)
                        normalized.type = member.type
                        normalized.mode = member.mode
                        normalized.size = member.size
                        normalized.linkname = member.linkname
                        normalized.uid = 0
                        normalized.gid = 0
                        normalized.uname = ""
                        normalized.gname = ""
                        normalized.mtime = 0
                        normalized.pax_headers = {}

                        if member.isfile():
                            content = source.extractfile(member)
                            if content is None:
                                raise RuntimeError(f"unable to read {member.name}")
                            output.addfile(normalized, content)
                        else:
                            output.addfile(normalized)


if __name__ == "__main__":
    main()
