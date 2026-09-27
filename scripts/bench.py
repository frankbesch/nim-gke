#!/usr/bin/env python3
"""Smoke test + small benchmark against a port-forwarded NIM (default localhost:8000).

Gate 4: /v1/models lists the model; one chat completion returns 200 with non-empty text.
Measures: N sequential non-streamed requests (latency p50/p95, completion tokens/s),
STREAM_N streamed requests (time to first token). Concurrency 1; numbers are
single-user, n small -- this is not a load test.

This is the script used for the 2026-09-27 measured run
(docs/runs/2026-09-27-measured-run.md), ported unchanged in method: same
prompts, same request shapes, same percentile math. Only argparse plumbing
was added so the run is reproducible without editing constants in the file.
"""
import argparse
import json
import statistics
import sys
import time
import urllib.error
import urllib.request

PROMPTS = [
    "Summarize the benefits of running LLM inference on Kubernetes in three sentences.",
    "Explain what a GPU node pool is to a finance manager in two sentences.",
    "List four risks of deploying an LLM in production and one control for each.",
    "Write a short checklist for smoke-testing an inference endpoint.",
]


def post(base, path, body, timeout=300):
    req = urllib.request.Request(
        base + path,
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    return urllib.request.urlopen(req, timeout=timeout)


def pct(xs, p):
    xs = sorted(xs)
    k = (len(xs) - 1) * p
    f = int(k)
    c = min(f + 1, len(xs) - 1)
    return xs[f] + (xs[c] - xs[f]) * (k - f)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--url", default="http://localhost:8000",
                     help="Base URL of the port-forwarded NIM (default: %(default)s)")
    ap.add_argument("--model", default="meta/llama3-8b-instruct",
                     help="Model id as reported by /v1/models (default: %(default)s)")
    ap.add_argument("--n", type=int, default=20,
                     help="Number of sequential non-streamed requests (default: %(default)s)")
    ap.add_argument("--stream-n", type=int, default=5, dest="stream_n",
                     help="Number of streamed requests for TTFT (default: %(default)s)")
    ap.add_argument("--max-tokens", type=int, default=256, dest="max_tokens",
                     help="max_tokens for the non-streamed timing requests (default: %(default)s)")
    ap.add_argument("--out", default=None,
                     help="Optional path to write the JSON result to (default: stdout only)")
    args = ap.parse_args()

    base = args.url.rstrip("/")

    out = {}
    try:
        models = json.load(urllib.request.urlopen(base + "/v1/models", timeout=30))
    except (urllib.error.URLError, ConnectionError, OSError) as e:
        print(f"ERROR: could not reach {base}/v1/models: {e}", file=sys.stderr)
        sys.exit(1)

    ids = [m["id"] for m in models.get("data", [])]
    out["models"] = ids
    assert args.model in ids, f"GATE 4 FAIL: {args.model} not in {ids}"

    t = time.time()
    r = post(base, "/v1/chat/completions", {
        "model": args.model, "max_tokens": 128, "messages": [
            {"role": "system", "content": "You are a polite chatbot."},
            {"role": "user", "content": "What should I do for a 4 day vacation in Spain?"}]})
    first = json.load(r)
    out["smoke_status"] = r.status
    out["smoke_s"] = round(time.time() - t, 3)
    text = first["choices"][0]["message"]["content"]
    assert r.status == 200 and text.strip(), "GATE 4 FAIL: empty completion"
    out["smoke_excerpt"] = text.strip()[:160]

    lat, tps, ctoks = [], [], []
    for i in range(args.n):
        t = time.time()
        d = json.load(post(base, "/v1/chat/completions", {
            "model": args.model, "max_tokens": args.max_tokens, "temperature": 0,
            "messages": [{"role": "user", "content": PROMPTS[i % len(PROMPTS)]}]}))
        dt = time.time() - t
        n = d["usage"]["completion_tokens"]
        lat.append(dt)
        ctoks.append(n)
        tps.append(n / dt)
    out["n"] = args.n
    out["latency_s"] = {"p50": round(pct(lat, .5), 3), "p95": round(pct(lat, .95), 3),
                         "max": round(max(lat), 3)}
    out["completion_tokens_mean"] = round(statistics.mean(ctoks), 1)
    out["tokens_per_s"] = {"p50": round(pct(tps, .5), 1), "min": round(min(tps), 1)}

    ttft = []
    for i in range(args.stream_n):
        t = time.time()
        r = post(base, "/v1/chat/completions", {
            "model": args.model, "max_tokens": 64, "stream": True,
            "messages": [{"role": "user", "content": PROMPTS[i % len(PROMPTS)]}]})
        for line in r:
            line = line.decode().strip()
            if line.startswith("data:") and '"content"' in line and line != "data: [DONE]":
                ttft.append(time.time() - t)
                break
        for _ in r:
            pass
    out["ttft_s"] = {"n": len(ttft), "p50": round(pct(ttft, .5), 3) if ttft else None,
                      "max": round(max(ttft), 3) if ttft else None}

    text_out = json.dumps(out, indent=2)
    print(text_out)
    if args.out:
        with open(args.out, "w") as f:
            f.write(text_out + "\n")


if __name__ == "__main__":
    main()
