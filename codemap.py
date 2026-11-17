#!/usr/bin/env python3
"""codemap.py: write a repo's CODEMAP.md from its code.

    python3 scripts/codemap.py <repo>        (from the workspace root)

C, Python, shell, JavaScript and Java go through graphify (`graphify update`,
no LLM) on a clean `git archive` export of HEAD, so nothing is written into
the repo except CODEMAP.md and generated output never lands in it. VHDL and
nand2tetris HDL, which graphify can't read, are parsed here directly:
entities, ports, processes and instances; chips and their parts.

Standard library only. Needs graphify (pipx install graphifyy) for the first
kind. CODEMAP.md is generated: regenerate it, don't edit it.
"""

import collections
import json
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

CODE_SUFFIXES = {".c", ".h", ".py", ".sh", ".bash", ".js", ".mjs", ".java", ""}
SKIP_PARTS = {"vendor", "node_modules", "fonts", "store", "archive", "build", "dist"}
HUBS = 15               # functions in the hub table and the call graph
MAX_FUNCS_PER_FILE = 60
MAX_CALLEES = 10
MAX_FILE_NODES = 25     # files drawn in the file graph


def run(cmd, cwd=None):
    return subprocess.run(cmd, cwd=cwd, check=True, capture_output=True, text=True).stdout


def mid(text):
    """A mermaid-safe node id."""
    return "n_" + re.sub(r"[^A-Za-z0-9_]", "_", text)


def q(text):
    """A mermaid-safe quoted label."""
    return '"' + text.replace('"', "'") + '"'


def kept(path):
    p = Path(path)
    return p.suffix in CODE_SUFFIXES and not (set(p.parts) & SKIP_PARTS)


# ---------------------------------------------------------------- graphify

def graphify_sections(export):
    out = subprocess.run(["graphify", "update", "."], cwd=export, capture_output=True, text=True)
    graph = export / "graphify-out" / "graph.json"
    if out.returncode != 0 or not graph.exists():
        return []
    g = json.loads(graph.read_text())
    nodes = {n["id"]: n for n in g["nodes"]}
    # shell functions aren't flagged _callable; their labels still end in "()"
    funcs = {i: n for i, n in nodes.items()
             if n.get("file_type") == "code" and kept(n.get("source_file", ""))
             and (n.get("_callable") or n.get("label", "").endswith("()"))}
    if not funcs:
        return []

    callees = collections.defaultdict(list)
    callers = collections.Counter()
    file_edges = collections.Counter()
    for link in g["links"]:
        if link.get("relation") != "calls":
            continue
        s, t = link["source"], link["target"]
        if s in funcs and t in funcs and s != t:
            if t not in callees[s]:
                callees[s].append(t)
                callers[t] += 1
            fs, ft = funcs[s]["source_file"], funcs[t]["source_file"]
            if fs != ft:
                file_edges[(fs, ft)] += 1

    degree = {i: len(callees[i]) + callers[i] for i in funcs}
    by_file = collections.defaultdict(list)
    for i, n in funcs.items():
        by_file[n["source_file"]].append(i)

    def line(i):
        loc = funcs[i].get("source_location") or ""
        return int(loc[1:]) if loc[1:].isdigit() else 0

    def name(i):
        return funcs[i]["label"]

    parts = []

    # files
    files = sorted(by_file, key=lambda f: -len(by_file[f]))[:MAX_FILE_NODES]
    shown = set(files)
    lines = ["## Files", "", "Each box is a source file and its function count; an arrow means calls into that file.", "",
             "```mermaid", "flowchart LR"]
    for f in files:
        lines.append(f"    {mid(f)}[{q(f + ' · ' + str(len(by_file[f])))}]")
    for (a, b), n in sorted(file_edges.items()):
        if a in shown and b in shown:
            lines.append(f"    {mid(a)} -->|{n}| {mid(b)}")
    lines += ["```", ""]
    if len(by_file) > len(files):
        lines += [f"({len(by_file) - len(files)} smaller files not drawn.)", ""]
    parts.append("\n".join(lines))

    # hubs
    hubs = sorted(funcs, key=lambda i: (-degree[i], name(i)))[:HUBS]
    hubs = [h for h in hubs if degree[h] > 0]
    if hubs:
        lines = ["## Hubs", "", "The most connected functions: where a change reaches furthest.", "",
                 "| Function | Where | Called by | Calls |", "|---|---|---|---|"]
        for h in hubs:
            lines.append(f"| `{name(h)}` | `{funcs[h]['source_file']}:{line(h)}` | {callers[h]} | {len(callees[h])} |")
        lines += ["", "```mermaid", "flowchart LR"]
        hs = set(hubs)
        dup = collections.Counter(name(h) for h in hubs)
        for h in hubs:   # a name used twice (two main()s) shows its file
            label = name(h) + (f"<br/>{funcs[h]['source_file']}" if dup[name(h)] > 1 else "")
            lines.append(f"    {mid(h)}[{q(label)}]")
        for h in hubs:
            for t in callees[h]:
                if t in hs:
                    lines.append(f"    {mid(h)} --> {mid(t)}")
        lines += ["```", ""]
        parts.append("\n".join(lines))

    # every function
    lines = ["## Functions", ""]
    for f in sorted(by_file):
        ids = sorted(by_file[f], key=line)
        if len(ids) > MAX_FUNCS_PER_FILE:
            top = set(sorted(ids, key=lambda i: -degree[i])[:MAX_FUNCS_PER_FILE])
            hidden = len(ids) - len(top)
            ids = [i for i in ids if i in top]
        else:
            hidden = 0
        lines += [f"### `{f}`", ""]
        for i in ids:
            cs = [name(t) for t in callees[i]]
            more = f", +{len(cs) - MAX_CALLEES}" if len(cs) > MAX_CALLEES else ""
            arrow = f" → {', '.join(f'`{c}`' for c in cs[:MAX_CALLEES])}{more}" if cs else ""
            lines.append(f"- `{name(i)}` L{line(i)}{arrow}")
        if hidden:
            lines.append(f"- … and {hidden} less-connected functions")
        lines.append("")
    parts.append("\n".join(lines))
    return parts


# ---------------------------------------------------------------- VHDL

def strip_vhdl_comments(text):
    return re.sub(r"--[^\n]*", "", text)


def vhdl_sections(root):
    files = sorted(p for p in root.rglob("*.vhd") if not (set(p.relative_to(root).parts) & SKIP_PARTS))
    if not files:
        return []
    entities = {}
    for path in files:
        src = strip_vhdl_comments(path.read_text(errors="replace"))
        for m in re.finditer(r"\bentity\s+(\w+)\s+is(.*?)\bend\b", src, re.S | re.I):
            ent, body = m.group(1), m.group(2)
            ports = re.findall(r"(\w+)\s*:\s*(in|out|inout|buffer)\b", body, re.I)
            generics = re.findall(r"(\w+)\s*:\s*(?:natural|integer|positive|time|boolean)\b", body.split("port", 1)[0] if "port" in body.lower() else body, re.I)
            entities[ent.lower()] = {"name": ent, "file": str(path.relative_to(root)), "ports": ports,
                                     "generics": generics, "procs": [], "insts": []}
        for m in re.finditer(r"\barchitecture\s+\w+\s+of\s+(\w+)\s+is(.*?)\bend\s+(?:architecture\b|\w+\s*;)", src, re.S | re.I):
            ent = entities.get(m.group(1).lower())
            if not ent:
                continue
            arch = m.group(2)
            for pm in re.finditer(r"\bprocess\s*(\(([^)]*)\))?(.*?)\bend\s+process", arch, re.S | re.I):
                sens = (pm.group(2) or "").replace(" ", "")
                driven = sorted(set(re.findall(r"\b(\w+)\s*<=", pm.group(3))))
                ent["procs"].append((sens, driven))
            for im in re.finditer(r"(\w+)\s*:\s*entity\s+\w+\.(\w+)", arch, re.I):
                ent["insts"].append((im.group(1), im.group(2)))
            for im in re.finditer(r"(\w+)\s*:\s*(?:component\s+)?(\w+)\s+(?:generic|port)\s+map", arch, re.I):
                if im.group(2).lower() != "entity" and (im.group(1), im.group(2)) not in ent["insts"]:
                    ent["insts"].append((im.group(1), im.group(2)))

    lines = ["## Design", "", "```mermaid", "flowchart TB"]
    for key, e in entities.items():
        lines.append(f"    {mid(key)}[{q(e['name'] + ' · ' + e['file'])}]")
    for key, e in entities.items():
        for label, child in e["insts"]:
            lines.append(f"    {mid(key)} -->|{label}| {mid(child.lower())}")
    lines += ["```", ""]
    for key, e in entities.items():
        ins = [p for p, d in e["ports"] if d.lower() == "in"]
        outs = [p for p, d in e["ports"] if d.lower() != "in"]
        lines += [f"### `{e['name']}` (`{e['file']}`)", "",
                  f"- **In:** {', '.join(f'`{p}`' for p in ins) or '-'}",
                  f"- **Out:** {', '.join(f'`{p}`' for p in outs) or '-'}"]
        if e["generics"]:
            lines.append(f"- **Generics:** {', '.join(f'`{g}`' for g in e['generics'])}")
        for n, (sens, driven) in enumerate(e["procs"], 1):
            lines.append(f"- **Process {n}** ({sens or 'no list'}): drives {', '.join(f'`{d}`' for d in driven) or '-'}")
        lines.append("")
    return ["\n".join(lines)]


# ---------------------------------------------------------------- HDL

def hdl_sections(root):
    files = sorted(root.rglob("*.hdl"))
    if not files:
        return []
    chips = {}
    for path in files:
        src = re.sub(r"/\*.*?\*/|//[^\n]*", "", path.read_text(errors="replace"), flags=re.S)
        m = re.search(r"\bCHIP\s+(\w+)", src)
        if not m:
            continue
        body = src.split("PARTS:", 1)[1] if "PARTS:" in src else ""
        parts = re.findall(r"\b([A-Z]\w*)\s*\(", body)
        chips[m.group(1)] = {"file": str(path.relative_to(root)), "parts": collections.Counter(parts)}
    builtin = sorted({p for c in chips.values() for p in c["parts"]} - set(chips))
    lines = ["## Chips", "", "Which chip is built from which, one graph per folder so each stays readable. "
             "A number on an arrow is how many of that part it uses; built-in chips: "
             f"{', '.join(f'`{b}`' for b in builtin)}.", ""]
    by_dir = collections.defaultdict(list)
    for name, c in chips.items():
        by_dir[str(Path(c["file"]).parent)].append(name)
    for folder in sorted(by_dir):
        lines += [f"### `{folder}`", "", "```mermaid", "flowchart LR"]
        for name in by_dir[folder]:
            for part, n in sorted(chips[name]["parts"].items()):
                label = f"|{n}| " if n > 1 else " "
                lines.append(f"    {mid(part)}[{part}] -->{label}{mid(name)}[{name}]")
        lines += ["```", ""]
    lines += ["| Chip | File | Parts |", "|---|---|---|"]
    for name, c in chips.items():
        parts = ", ".join(f"{p}×{n}" if n > 1 else p for p, n in sorted(c["parts"].items()))
        lines.append(f"| `{name}` | `{c['file']}` | {parts} |")
    lines.append("")
    return ["\n".join(lines)]


# ---------------------------------------------------------------- main

def main():
    if len(sys.argv) != 2:
        print(__doc__.strip().splitlines()[2].strip(), file=sys.stderr)
        return 1
    repo = Path(sys.argv[1]).resolve()
    sha = run(["git", "-C", str(repo), "rev-parse", "--short", "HEAD"]).strip()
    export = Path(tempfile.mkdtemp(prefix="codemap-"))
    try:
        archive = subprocess.run(["git", "-C", str(repo), "archive", "HEAD"],
                                 check=True, capture_output=True).stdout
        tar = export / "head.tar"
        tar.write_bytes(archive)
        with tarfile.open(tar) as t:
            t.extractall(export / "src")
        src = export / "src"
        # drop vendored and data folders before graphify sees them: on a
        # repo like adleros the vendor bundles are most of the graph, and
        # loading them can run a small machine out of memory
        for d in sorted(src.rglob("*"), reverse=True):
            if d.is_dir() and d.name in SKIP_PARTS:
                shutil.rmtree(d, ignore_errors=True)
        sections = hdl_sections(src) + vhdl_sections(src)
        if shutil.which("graphify"):
            sections += graphify_sections(src)
        else:
            print("codemap: graphify not found, skipping C/Python/shell/JS (pipx install graphifyy)", file=sys.stderr)
    finally:
        shutil.rmtree(export, ignore_errors=True)

    if not sections:
        print(f"codemap: no code found in {repo.name}", file=sys.stderr)
        return 1
    head = (f"# Codemap: {repo.name}\n\n← [README](README.md)\n\n"
            f"> Generated from commit `{sha}` by `scripts/codemap.py`. Regenerate it from the workspace root "
            f"with `python3 scripts/codemap.py {repo.name}`; don't edit it by hand.\n\n")
    (repo / "CODEMAP.md").write_text(head + "\n".join(sections).rstrip() + "\n")
    print(f"{repo.name}: CODEMAP.md from {sha}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
