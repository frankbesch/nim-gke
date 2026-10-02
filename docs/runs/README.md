# Measured runs

Each Markdown file here is the receipt of one live run against a real Google
Cloud project. Costs in the receipts are estimates at list prices from the
Cloud Billing Catalog API, with durations as upper bounds.

## Posted cost

The Cloud Billing report for 2026-09-26 to 2026-09-30, read on 2026-10-02,
covers all five starts below. The report groups by service, not by run, so
the receipts keep their per-run estimates.

| Service | List cost | Credits | Charged |
|---|---|---|---|
| Compute Engine | $0.94 | $0.00 | $0.94 |
| Kubernetes Engine | $0.19 | -$0.19 | $0.00 |
| Networking | $0.05 | -$0.05 | $0.00 |
| Cloud Monitoring | $0.01 | $0.00 | $0.01 |
| **Total** | **$1.19** | **-$0.24** | **$0.95** |

The estimates for the same starts sum to about $1.34. They were high by about
$0.15 at list cost, as an upper bound should be. The credit covered the whole
cluster fee, which run 1's receipt had marked as not verified. The estimates
left out networking and monitoring, $0.06 together.

## Receipts

| Run | Mode | Result |
|---|---|---|
| [2026-09-27, run 1](2026-09-27-measured-run.md) | Fixed, one `g2-standard-4` with one L4 | PASS: deploy to Ready 20 m 19 s; destroy clean |
| [2026-09-27, run 2](2026-09-27-run-2.md) | Fixed, updated scripts | Deploy and benchmark PASS; destroy FAIL, one disk left |
| [2026-09-28, run 3](2026-09-28-run-3-autoscale.md) | Autoscale, GPU pool 0 to 1 to 0 | PASS: scale-up 1 m 17 s, scale-down 12 m 32 s; destroy clean |

## Every attempt, including the failures

Five starts produced the three receipts above. Times are UTC.

| # | Date, start | Duration | Attempt | Outcome | Cause | Fix | Cost, estimate |
|---|---|---|---|---|---|---|---|
| 1 | 09-27, 18:56 | 31 min | Fixed pool, run 1 | PASS | none | none | $0.43 |
| 2 | 09-27, 23:03 | seconds | Fixed pool, preflight | False FAIL on "no existing cluster"; nothing created | `gcloud` prints a warning to stderr when no cluster matches. Preflight read it as a cluster name. | `d78e61c`: read stdout only | $0 |
| 3 | 09-27, 23:09 | 30 min | Fixed pool, run 2 | Deploy and benchmark PASS; destroy left one 50 GiB disk | Cleanup deleted the cluster while the pod still held the disk, so the driver could not delete it | `d78e61c`: wait for pods and volumes before the cluster delete. Proven in run 3. | $0.40, plus the disk at about $0.0068 per hour until deleted |
| 4 | 09-28, time not recorded | not recorded | Autoscale, first start | FAIL: a closed terminal pane killed the runner and its watchdog together. One cluster was stranded and deleted by hand. | The watchdog ran inside the terminal's process group | `5279c9e`, `057440b`: the watchdog runs in its own session and takes over cleanup | about $0.05 |
| 5 | 09-28, 19:48 | 39 min | Autoscale, run 3 | PASS | none | none | about $0.46 |

Attempt 4 has no receipt. Its cost is an estimate from the time the cluster
existed. The time the orphaned disk from attempt 3 was deleted is not
recorded, so its cost has no total.

What the failures changed in the kit:

- Cleanup now waits for each volume to go before it deletes the cluster, and
  then checks the project for leftover disks.
- The runner's watchdog survives a closed terminal and a kill of the process
  group. Tests H1, H2, K1, K2, and G1 cover it.
- Preflight reads only stdout from `gcloud`.
