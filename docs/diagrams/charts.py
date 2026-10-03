#!/usr/bin/env python3
"""Draw the README diagrams and charts as light and dark SVG.

Usage: python3 docs/diagrams/charts.py
Writes six charts as <name>-light.svg and <name>-dark.svg, in three pairs of
equal height (PAIRS, D-262). Every figure is copied from the README
and docs/runs/. Change a figure there first, then here. The drawing code is
quoin_readme.py, a copy kept in step by promptkits/quoin/github/sync.py.
"""
from pathlib import Path

from quoin_readme import (THEMES, GREEN, BLUE, OCHRE, RED, STEEL, M, R, text, rect, para, note,
                          head, svg, pair, panels, deploys, runner_ends, measured, autoscale)

HERE = Path(__file__).resolve().parent

MEASURED = dict(
    title="Measured side by side",
    names=["OKE, one A10", "GKE, one L4"],
    panels=[
        ("Scale-up: pod Pending to GPU node Ready", [(385, "385 s"), (77, "77 s")]),
        ("Scale-down: zero replicas to no GPU node",
         [(312, "312 s, timers set to 3 min"), (752, "752 s, default delay")]),
        ("Script start to NIM Ready, autoscale", [(1384, "23 min 04 s"), (967, "16 min 07 s")]),
        ("Posted list cost, every start", [(1.17, "$1.17"), (1.19, "$1.19")]),
    ],
    note=("One run each, on different hardware. This is a record of each run, "
          "not a benchmark of the two platforms."),
    desc=("Scale-up 385 s on OKE and 77 s on GKE. Scale-down 312 s on OKE with timers set to "
          "3 minutes and 752 s on GKE with the default delay. Script start to NIM Ready with "
          "autoscale 23 min 04 s on OKE and 16 min 07 s on GKE. Posted list cost for every "
          "start $1.17 on OKE and $1.19 on GKE."),
)

COST_DESC = ("Posted list cost $1.19 for five starts: L4 GPU $0.5608, G2 host VM $0.1471, E2 system "
            "node $0.1887, persistent disk $0.0440, Kubernetes Engine fee $0.19 credited, networking "
            "$0.05 credited, Cloud Monitoring $0.01. Charged after credits $0.95.")


# Box entries: (name, description, coloured line or None[, kind]).
DEPLOYS = dict(
    title="nim-gke: what it deploys",
    desc=("A client (curl or an OpenAI SDK) calls the NIM pod over the OpenAI-compatible API. The NIM "
          "pod runs llama3-8b-instruct 1.0.0 with backend profile vllm-fp16-tp1. It pulls its image "
          "from the NGC registry and keeps model files on a 50 GiB persistent disk. It is scheduled on "
          "one GPU node, g2-standard-4 with one NVIDIA L4. With AUTOSCALE=1, the GKE cluster "
          "autoscaler adds and removes that node. The pod, disk, GPU node, and autoscaler sit inside "
          "the GKE cluster in us-central1-a."),
    client=("Client", "curl or OpenAI SDK"),
    ngc=("NGC registry", "nvcr.io/nim/meta"),
    nim=("NIM pod", "llama3-8b-instruct 1.0.0", "vllm-fp16-tp1"),
    cache=("Persistent disk", "50 GiB model cache"),
    gpu=("GPU node", "g2-standard-4, one L4", "pool 0 to 1 with AUTOSCALE=1"),
    autoscaler=("Cluster autoscaler", "managed by GKE"),
    cluster="GKE cluster, us-central1-a",
)
RUNNER = dict(
    title="How the runner ends",
    desc=("The runner sets a trap and arms a watchdog in its own session. The steps run: deploy and "
          "benchmark. Cleanup runs from the trap on every exit. When cleanup is confirmed, the runner "
          "exits with the cluster deleted. If the runner dies or the time limit passes, the watchdog "
          "runs cleanup. If cleanup cannot be confirmed, the runner prints the gcloud delete commands "
          "and leaves the watchdog armed."),
    lanes=("Runner", "Watchdog, own session"),
    preflight=("Start runner", "trap is set", None, "backend"),
    arm=("Arm watchdog", "own session", None, "security"),
    steps=("Run steps", "deploy and benchmark", None, "backend"),
    teardown=("Cleanup", "trap on every exit", None, "backend"),
    confirm=("Cleanup confirmed", "cluster and disks gone", None, "security"),
    done=("Exit", "cluster deleted", None, "cloud"),
    takeover=("Watchdog cleanup", "runner died or time limit", None, "bus"),
    manual=("Manual delete", "prints gcloud commands", "watchdog stays armed", "external"),
)
AUTOSCALE = dict(
    serving="benchmark, then replicas 0", up="scale-up: 1 m 17 s", down="scale-down: 12 m 32 s",
    foot="Run 3, 2026-09-28, one NVIDIA L4. Measured once. Scale-down used GKE's default delay.",
    desc=("The GPU node pool starts at 0 nodes. The NIM pod goes Pending and asks for one GPU. "
          "The GPU node is Ready 1 m 17 s later. NIM serves the benchmark, then replicas are set "
          "to 0. The pool is back at 0 nodes 12 m 32 s after that."),
)


def cost(c, spread=0.0, h=0):
    """Posted Google Cloud list cost for both days, one panel per billing line on
    one dollar scale (the ggplot2 trial's layout, Frank 2026-10-02)."""
    lines = [("GPU, NVIDIA L4", 0.5608, GREEN),
             ("GPU host VM, G2 cores and memory", 0.1471, BLUE),
             ("System node, E2 cores and memory", 0.1887, OCHRE),
             ("Balanced persistent disk", 0.0440, STEEL),
             ("Kubernetes Engine fee, credited", 0.19, "ink2"),
             ("Networking, credited", 0.05, "ink2"),
             ("Cloud Monitoring", 0.01, "ink2")]

    def shown(v):
        return f"${v:.4f}" if v != round(v, 2) or v == 0.044 else f"${v:.2f}"

    return panels(dict(
        title="Posted Google Cloud cost by billing line",
        sub="All five starts, 2026-09-27 and 2026-09-28: $1.19 list.",
        panels=[(name, colour, [("", v, shown(v))]) for name, v, colour in lines],
        notes=["Charged after credits: $0.95. Posted usage from the Cloud Billing report, "
               "read on 2026-10-02. Not an invoice.", "The report splits by day, not by run."],
        desc=COST_DESC), c, spread, h)


def attempts(c, spread=0.0, h=0):
    """Five starts over two days, as duration bars.
    spread opens the gap between rows."""
    rows = [  # label, when, minutes (None = not recorded), PASS, note
        ("1  Fixed pool, run 1", "09-27 18:56", 31, True, "PASS · 31 min · $0.43 estimate"),
        ("2  Fixed pool, preflight", "09-27 23:03", 0, False, "false FAIL · seconds · $0"),
        ("3  Fixed pool, run 2", "09-27 23:09", 30, True, "PASS; one 50 GiB disk left · 30 min · $0.40 estimate"),
        ("4  Autoscale, first start", "09-28", None, False, "FAIL; cluster stranded · duration not recorded · about $0.05"),
        ("5  Autoscale, run 3", "09-28 19:48", 39, True, "PASS · 39 min · about $0.46 estimate"),
    ]
    b, y = head("Every attempt on 2026-09-27 and 2026-09-28", c)
    for label, when, minutes, ok, shown in rows:
        colour = c["series"][GREEN] if ok else c["series"][RED]
        b.append(text(M, y, label, 13, c["ink"]))
        b.append(text(M, y + 18, when + " UTC" if ":" in when else when + ", time not recorded", 12, c["ink2"]))
        if minutes is None:
            b.append(f'<rect x="{M}" y="{y + 27}" width="40" height="14" rx="2" fill="none" stroke="{colour}" stroke-dasharray="4 3"/>')
        else:
            b.append(rect(M, y + 27, max(minutes * 8.0, 5), 14, colour))
        lines, y = para(M, y + 59, shown, 12, c["ink"], R - M)
        b += lines
        y += 12 + round(20 * spread)
    foot, y = note(y + 4, "Bar length is run duration. Per-run costs are estimates at list price; "
                   "the posted total for both days is $1.19.", c)
    desc = ("Five starts. 09-27 18:56 fixed pool run 1 passed in 31 minutes. 09-27 23:03 preflight "
            "gave a false fail. 09-27 23:09 fixed pool run 2 passed in 30 minutes and left one 50 GiB "
            "disk. 09-28 the first autoscale start failed and stranded a cluster. 09-28 19:48 autoscale "
            "run 3 passed in 39 minutes.")
    return svg(max(y, h), "Every attempt on 2026-09-27 and 2026-09-28", desc, b + foot, c)


# The README shows these as pairs, one per line, at one height (D-262).
PAIRS = [("measured", lambda c, s=0.0, h=0: measured(MEASURED, c, s, h), "attempts", attempts),
         ("deploys", lambda c, s=0.0, h=0: deploys(DEPLOYS, c, s, h), "cost", cost),
         ("autoscale", lambda c, s=0.0, h=0: autoscale(AUTOSCALE, c, s, h),
          "runner-ends", lambda c, s=0.0, h=0: runner_ends(RUNNER, c, s, h))]


def main():
    for theme, c in THEMES.items():
        for ln, lf, rn, rf in PAIRS:
            for name, s in zip((ln, rn), pair(lf, rf, c)):
                (HERE / f"{name}-{theme}.svg").write_text(s)
    print("built", ", ".join(f"{ln} | {rn}" for ln, _, rn, _ in PAIRS))

if __name__ == "__main__":
    main()
