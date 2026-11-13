#!/usr/bin/env python3
"""Wire loki.command on querier and index-gateway in the vendored grafana/loki 7.0.0 chart.

Those two templates ship args only. The RH logging-loki-rhel9 image has no
ENTRYPOINT, so args would be argv0. Other Distributed components already honor
loki.command. Re-run after make helm-deps CHART=argocd/config/regional-cluster/loki.
"""
from __future__ import annotations

import io
import sys
import tarfile
from pathlib import Path

CHART = Path("argocd/config/regional-cluster/loki/charts/loki-7.0.0.tgz")
JOBS = {
    "loki/templates/querier/deployment-querier.yaml": "querier",
    "loki/templates/index-gateway/statefulset-index-gateway.yaml": "indexGateway",
}
NEEDLE = """          image: {{ include "loki.image" . }}
          imagePullPolicy: {{ .Values.loki.image.pullPolicy }}
          args:
"""


def insert_for(component: str) -> str:
    return (
        '          image: {{ include "loki.image" . }}\n'
        "          imagePullPolicy: {{ .Values.loki.image.pullPolicy }}\n"
        "          {{- if or .Values.loki.command .Values.COMPONENT.command }}\n"
        "          command:\n"
        "            - {{ coalesce .Values.COMPONENT.command .Values.loki.command | quote }}\n"
        "          {{- end }}\n"
        "          args:\n"
    ).replace("COMPONENT", component)


def main() -> int:
    if not CHART.is_file():
        print(f"missing {CHART}", file=sys.stderr)
        return 1
    with tarfile.open(CHART, "r:gz") as tar:
        members = {m.name: m for m in tar.getmembers()}
        files = {name: tar.extractfile(name).read() for name in JOBS}
    patched: dict[str, bytes] = {}
    for name, component in JOBS.items():
        text = files[name].decode()
        if "Values.loki.command" in text:
            print(f"already patched {name}")
            patched[name] = files[name]
            continue
        if NEEDLE not in text:
            print(f"pattern not found in {name}", file=sys.stderr)
            return 1
        patched[name] = text.replace(NEEDLE, insert_for(component), 1).encode()
        print(f"patched {name}")
    out = io.BytesIO()
    with tarfile.open(CHART, "r:gz") as src, tarfile.open(fileobj=out, mode="w:gz") as dst:
        for member in src.getmembers():
            data = patched.get(member.name)
            if data is None:
                extracted = src.extractfile(member)
                data = extracted.read() if extracted is not None else b""
            info = tarfile.TarInfo(name=member.name)
            info.size = len(data)
            info.mtime = member.mtime
            info.mode = member.mode
            info.type = member.type
            info.uid = member.uid
            info.gid = member.gid
            info.uname = member.uname
            info.gname = member.gname
            dst.addfile(info, io.BytesIO(data))
    CHART.write_bytes(out.getvalue())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
