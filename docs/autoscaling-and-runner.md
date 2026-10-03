# GPU node autoscaling and how the runner ends

<picture><source media="(prefers-color-scheme: dark)" srcset="diagrams/autoscale-dark.svg"/><img width="400" align="top" src="diagrams/autoscale-light.svg" alt="Chart: the GPU node pool goes from 0 nodes to 1 and back to 0, with the measured scale-up and scale-down times."/></picture> <picture><source media="(prefers-color-scheme: dark)" srcset="diagrams/runner-ends-dark.svg"/><img width="400" align="top" src="diagrams/runner-ends-light.svg" alt="Workflow: start the runner, arm the watchdog, run the steps, clean up, then exit when cleanup is confirmed; otherwise print the manual delete commands with the watchdog still armed."/></picture>

<details><summary>Text version of the diagrams</summary>

The GPU node pool starts at 0 nodes. The NIM pod goes Pending and asks for one GPU. The GPU node is Ready 1 m 17 s later. NIM serves the benchmark, then replicas are set to 0. The pool is back at 0 nodes 12 m 32 s after that.

The runner sets a trap and arms a watchdog in its own session. The steps run: deploy and benchmark. Cleanup runs from the trap on every exit. When cleanup is confirmed, the runner exits with the cluster deleted. If the runner dies or the time limit passes, the watchdog runs cleanup. If cleanup cannot be confirmed, the runner prints the `gcloud` delete commands and leaves the watchdog armed.

</details>

`--autoscale` creates the GPU pool with no nodes and autoscaling from 0 to 1.
The pending NIM pod triggers one GPU node. After the benchmark, the runner
scales NIM to zero replicas and waits for the autoscaler to remove the node.

```bash
scripts/run_measured.sh --autoscale /tmp/nim-run-autoscale
```

Scope: one GPU node, measured once, in
[run 3](runs/2026-09-28-run-3-autoscale.md).

## How the runner ends

- A trap runs cleanup on success, failure, Ctrl-C, and `TERM`.
- A watchdog runs in its own session, outside the terminal's process tree. It
  takes over cleanup if the runner dies, and at a time limit.
- If cleanup cannot be confirmed, the runner leaves the watchdog armed and
  prints the `gcloud` commands to delete by hand.

The runner's behaviour is tested with stubs in `tests/`. Those tests make no
cloud call.
