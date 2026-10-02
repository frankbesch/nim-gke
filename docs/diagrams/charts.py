#!/usr/bin/env python3
"""Draw the README charts as light and dark SVG.

Usage: python3 docs/diagrams/charts.py
Writes measured-*.svg, cost-*.svg, attempts-*.svg, and autoscale-*.svg next to this file.
Every figure is copied from the README tables and docs/runs/README.md. Change a figure
there first, then here.
"""
from html import escape
from pathlib import Path

HERE = Path(__file__).resolve().parent
W = 1000
MONO = 'ui-monospace, "SFMono-Regular", "SF Mono", Menlo, Consolas, monospace'

# Quoin tokens (chrome) and Quoin chart palette (data marks).
THEMES = {
    "light": dict(paper="#FCFBF9", ink="#2B2926", ink2="#6A625A", rule="#D2CCC3", tint="#EBE6DD",
                  series=["#33703F", "#0084A9", "#916A0B", "#90302B", "#23749E"]),
    "dark": dict(paper="#0E1C2B", ink="#E8E2D6", ink2="#A8A296", rule="#2D4152", tint="#1F3142",
                 series=["#6DA361", "#17A1C8", "#9C7300", "#D17276", "#559ACA"]),
}
GREEN, BLUE, OCHRE, RED, STEEL = range(5)


def text(x, y, s, size, fill, anchor="start", weight=None, ls=0):
    extra = ""
    if anchor != "start":
        extra += f' text-anchor="{anchor}"'
    if weight:
        extra += f' font-weight="{weight}"'
    if ls:
        extra += f' letter-spacing="{ls}"'
    return f'<text x="{x}" y="{y}" font-size="{size}" fill="{fill}"{extra}>{escape(s)}</text>'


def rect(x, y, w, h, fill, rx=2):
    return f'<rect x="{x:.1f}" y="{y}" width="{max(w, 0):.1f}" height="{h}" rx="{rx}" fill="{fill}"/>'


def svg(h, title, desc, body, c):
    return (
        f'<svg viewBox="0 0 {W} {h}" xmlns="http://www.w3.org/2000/svg" role="img" '
        f'font-family=\'{MONO}\'>\n<title>{escape(title)}</title>\n<desc>{escape(desc)}</desc>\n'
        f'<rect width="{W}" height="{h}" rx="6" fill="{c["paper"]}"/>\n'
        + text(40, 44, title, 17, c["ink"], weight=600)
        + f'\n<line x1="40" y1="60" x2="960" y2="60" stroke="{c["rule"]}"/>\n'
        + "\n".join(body) + "\n</svg>\n"
    )


def measured(c):
    """Four paired bars: nimble-oke on OKE against nim-gke on GKE."""
    panels = [
        ("Scale-up: pod Pending to GPU node Ready", [(385, "385 s"), (77, "77 s")]),
        ("Scale-down: zero replicas to no GPU node",
         [(312, "312 s, timers set to 3 min"), (752, "752 s, default delay")]),
        ("Script start to NIM Ready, autoscale", [(1384, "23 min 04 s"), (967, "16 min 07 s")]),
        ("Posted list cost, every start", [(1.17, "$1.17"), (1.19, "$1.19")]),
    ]
    names = ["OKE, one A10", "GKE, one L4"]
    colours = [c["series"][GREEN], c["series"][BLUE]]
    b = []
    for i, (label, rows) in enumerate(panels):
        x0 = 40 + (i % 2) * 470
        y0 = 96 + (i // 2) * 150
        b.append(text(x0, y0, label, 12.5, c["ink"], weight=600))
        top = max(v for v, _ in rows)
        for j, (v, shown) in enumerate(rows):
            y = y0 + 18 + j * 42
            b.append(text(x0, y + 15, names[j], 11.5, c["ink2"]))
            b.append(rect(x0 + 110, y, 330, 22, c["tint"]))
            w = 330 * v / top
            b.append(rect(x0 + 110, y, w, 22, colours[j]))
            b.append(text(x0 + 110, y + 36, shown, 11.5, c["ink"]))
    b.append(f'<line x1="40" y1="398" x2="960" y2="398" stroke="{c["rule"]}"/>')
    b.append(text(40, 422, "One run each, on different hardware. This is a record of each run, "
                  "not a benchmark of the two platforms.", 11.5, c["ink2"]))
    desc = ("Scale-up 385 s on OKE and 77 s on GKE. Scale-down 312 s on OKE with timers set to "
            "3 minutes and 752 s on GKE with the default delay. Script start to NIM Ready with "
            "autoscale 23 min 04 s on OKE and 16 min 07 s on GKE. Posted list cost for every "
            "start $1.17 on OKE and $1.19 on GKE.")
    return svg(444, "Measured side by side", desc, b, c)


def cost(c):
    """Posted Google Cloud list cost for both days, stacked by billing line."""
    lines = [("GPU, NVIDIA L4", 0.5608, c["series"][GREEN]),
             ("GPU host VM, G2 cores and memory", 0.1471, c["series"][BLUE]),
             ("System node, E2 cores and memory", 0.1887, c["series"][OCHRE]),
             ("Balanced persistent disk", 0.0440, c["series"][STEEL]),
             ("Kubernetes Engine fee, credited", 0.19, c["ink2"]),
             ("Networking, credited", 0.05, c["ink2"]),
             ("Cloud Monitoring", 0.01, c["ink2"])]
    scale = 760 / 1.19
    b = [text(40, 86, "All five starts, 2026-09-27 and 2026-09-28", 12.5, c["ink"])]
    x = 40.0
    for _, v, colour in lines:
        b.append(rect(x, 100, v * scale - 1.5, 28, colour, rx=1))
        x += v * scale
    b.append(text(x + 10, 119, "$1.19 list", 13, c["ink"], weight=600))
    b.append(f'<line x1="40" y1="152" x2="960" y2="152" stroke="{c["rule"]}"/>')
    b.append(text(600, 178, "List cost", 11.5, c["ink2"], anchor="end"))
    for k, (name, v, colour) in enumerate(lines):
        y = 202 + k * 24
        b.append(rect(40, y - 11, 12, 12, colour))
        b.append(text(62, y, name, 12, c["ink"]))
        shown = f"${v:.4f}" if v != round(v, 2) or v == 0.044 else f"${v:.2f}"
        b.append(text(600, y, shown, 12, c["ink"], anchor="end"))
    b.append(text(40, 386, "Charged after credits: $0.95. Posted usage from the Cloud Billing report, "
                  "read on 2026-10-02. Not an invoice.", 11.5, c["ink2"]))
    b.append(text(40, 406, "The report splits by day, not by run.", 11.5, c["ink2"]))
    desc = ("Posted list cost $1.19 for five starts: L4 GPU $0.5608, G2 host VM $0.1471, E2 system "
            "node $0.1887, persistent disk $0.0440, Kubernetes Engine fee $0.19 credited, networking "
            "$0.05 credited, Cloud Monitoring $0.01. Charged after credits $0.95.")
    return svg(428, "Posted Google Cloud cost by billing line", desc, b, c)


def attempts(c):
    """Five starts over two days, as duration bars."""
    rows = [  # label, when, minutes (None = not recorded), PASS, note
        ("1  Fixed pool, run 1", "09-27 18:56", 31, True, "PASS · 31 min · $0.43 estimate"),
        ("2  Fixed pool, preflight", "09-27 23:03", 0, False, "false FAIL · seconds · $0"),
        ("3  Fixed pool, run 2", "09-27 23:09", 30, True, "PASS; one 50 GiB disk left · 30 min · $0.40 estimate"),
        ("4  Autoscale, first start", "09-28", None, False, "FAIL; cluster stranded · duration not recorded · about $0.05"),
        ("5  Autoscale, run 3", "09-28 19:48", 39, True, "PASS · 39 min · about $0.46 estimate"),
    ]
    b = []
    for i, (label, when, minutes, ok, note) in enumerate(rows):
        y = 84 + i * 46
        colour = c["series"][GREEN] if ok else c["series"][RED]
        b.append(text(40, y + 13, label, 12.5, c["ink"]))
        b.append(text(40, y + 30, when + " UTC" if ":" in when else when + ", time not recorded", 10.5, c["ink2"]))
        w = max((minutes or 0) * 4.2, 6)
        if minutes is None:
            b.append(f'<rect x="270" y="{y}" width="40" height="24" rx="2" fill="none" stroke="{colour}" stroke-dasharray="4 3"/>')
            w = 40
        else:
            b.append(rect(270, y, w, 24, colour))
        b.append(text(270 + w + 10, y + 17, note, 11.5, c["ink"]))
    b.append(text(40, 336, "Bar length is run duration. Per-run costs are estimates at list price; "
                  "the posted total for both days is $1.19.", 11.5, c["ink2"]))
    desc = ("Five starts. 09-27 18:56 fixed pool run 1 passed in 31 minutes. 09-27 23:03 preflight "
            "gave a false fail. 09-27 23:09 fixed pool run 2 passed in 30 minutes and left one 50 GiB "
            "disk. 09-28 the first autoscale start failed and stranded a cluster. 09-28 19:48 autoscale "
            "run 3 passed in 39 minutes.")
    return svg(358, "Every attempt on 2026-09-27 and 2026-09-28", desc, b, c)


def autoscale(c):
    """The GPU node pool going 0 to 1 to 0 in run 3, with the two measured spans."""
    steps = [("Pool at 0 nodes", "cluster up, no GPU"),
             ("NIM pod Pending", "asks for one GPU"),
             ("GPU node Ready", "autoscaler added it"),
             ("NIM serving", "benchmark, then replicas 0"),
             ("Pool back at 0", "autoscaler removed it")]
    b = []
    for i, (label, sub) in enumerate(steps):
        x = 40 + i * 190
        edge = c["series"][GREEN] if i in (0, 4) else c["rule"]
        b.append(f'<rect x="{x}" y="92" width="160" height="66" rx="4" fill="{c["tint"]}" stroke="{edge}"/>')
        b.append(text(x + 80, 120, label, 12.5, c["ink"], anchor="middle", weight=600))
        b.append(text(x + 80, 141, sub, 10.5, c["ink2"], anchor="middle"))
        if i < 4:
            b.append(f'<path d="M{x + 164} 125 H{x + 182} m-6 -5 l6 5 l-6 5" fill="none" stroke="{c["ink2"]}" stroke-width="1.5"/>')
    for first, label, colour in ((1, "scale-up: 1 m 17 s", GREEN), (3, "scale-down: 12 m 32 s", BLUE)):
        xa, xb = 40 + first * 190 + 80, 40 + (first + 1) * 190 + 80
        b.append(f'<path d="M{xa} 170 V182 H{xb} V170" fill="none" stroke="{c["series"][colour]}" stroke-width="2"/>')
        b.append(text((xa + xb) / 2, 204, label, 13, c["ink"], anchor="middle", weight=600))
    b.append(text(40, 244, "Run 3, 2026-09-28, one NVIDIA L4. Measured once. "
                  "Scale-down used GKE's default delay.", 11.5, c["ink2"]))
    desc = ("The GPU node pool starts at 0 nodes. The NIM pod goes Pending and asks for one GPU. "
            "The GPU node is Ready 1 m 17 s later. NIM serves the benchmark, then replicas are set "
            "to 0. The pool is back at 0 nodes 12 m 32 s after that.")
    return svg(266, "GPU node autoscaling, 0 to 1 to 0", desc, b, c)


def main():
    for name, fn in (("measured", measured), ("cost", cost), ("attempts", attempts),
                     ("autoscale", autoscale)):
        for theme, c in THEMES.items():
            (HERE / f"{name}-{theme}.svg").write_text(fn(c))
        print("built", name)


if __name__ == "__main__":
    main()
