"""Turns Flutter analyzer / build errors into GitHub annotations.

Annotations can be read through the GitHub API (check-runs/<id>/annotations),
which lets the assistant see compile errors without downloading logs.
"""
import sys

path, kind = sys.argv[1], sys.argv[2]
try:
    lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
except OSError:
    sys.exit(0)

if kind == "analyze":
    picked = [l.strip() for l in lines if l.strip().startswith(("error •", "warning •"))]
else:
    picked = []
    for i, l in enumerate(lines):
        low = l.lower()
        if "error:" in low or ": error" in low or "error c" in low or "exception" in low or "failed" in low or "what went wrong" in low:
            picked.extend(x.strip() for x in lines[i:i + 3])
    picked = list(dict.fromkeys(p for p in picked if p))

if not picked:
    sys.exit(0)

def enc(s):
    return s.replace("%", "%25").replace("\r", "").replace("\n", "%0A")

# GitHub keeps 10 annotations per step; pack lines into chunks.
chunk, chunks = [], []
for l in picked[:400]:
    chunk.append(l)
    if len("\n".join(chunk)) > 3500:
        chunks.append(chunk)
        chunk = []
if chunk:
    chunks.append(chunk)
for c in chunks[:10]:
    level = "error" if kind == "build" or any(x.startswith("error") for x in c) else "warning"
    print(f"::{level} title={kind}::" + enc("\n".join(c)))
