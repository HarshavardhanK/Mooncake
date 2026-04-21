# VP-support ticket — unblock Stages B/C/D for the PrfaaS experiment

Copy/paste-ready text for whatever support channel you use.

---

**Subject:** Need GPU access on g304 and g307 for a Mooncake / PrfaaS experiment (no host driver changes requested)

**Hi VP-support,**

I'm running a research experiment on Mooncake-based prefill/decode disaggregation across two of our DCs and have hit a few cluster-policy blockers on the two Cluster-X nodes. None of these require touching the GPU drivers (which I understand the GPU Operator owns).

**Nodes affected:**
- `g304.iad1.voltagepark.net` (159.26.81.50) — `vpsupport@`, NOPASSWD sudo present
- `g307.iad1.voltagepark.net` (159.26.81.53) — `vpsupport@`, NOPASSWD sudo NOT present

**What I see today** (read-only inspection, full report attached):
1. `nvidia-smi` from the host shell on both g304 and g307 returns "couldn't communicate with the NVIDIA driver" — GPUs are visible only inside containers/pods that the GPU Operator schedules. (For comparison, on `g126.lga1` (147.185.40.126), `nvidia-smi` works directly from the host shell.)
2. `g304` carries a `voltagepark.io/cni-pending=true:NoSchedule` taint and `voltagepark.io/gpu-validated=false`.
3. `vpsupport` on g307 has no NOPASSWD sudo (it does on g304 and g126).

**What I'd like — pick whichever path is easiest for you:**

**Path A (preferred — host-level):**
- On g304: clear the `voltagepark.io/cni-pending=true:NoSchedule` taint and run the GPU validation so `voltagepark.io/gpu-validated=true`.
- On both g304 and g307: ensure `nvidia-smi` works from the host shell as `vpsupport` (this is how it works on g126 today).
- Grant NOPASSWD sudo to `vpsupport` on g307 (matching g304).
- I won't install or modify NVIDIA drivers — the workload uses `--gpus all` against whatever NVIDIA Container Runtime the operator already wires up.

**Path B (alternative — pod-scoped):**
- A namespace where I can `kubectl apply` GPU-requesting Pods on g304 and g307. I'll containerize vLLM and Mooncake. NodeSelector or affinity rules to pin to these two nodes are fine.
- I'd just need: kubeconfig + namespace, a GPU resource quota that allows up to 8 H100 / pod, and confirmation that the cluster has an `nvidia.com/gpu` extended resource exposed.

**Why I need it:**
- Stage B of the experiment runs vLLM on both g304 and g307 in a 1-prefill / 1-decode disaggregation, with KV cache transferred over the bootnet (100 Gbps) between them.
- Stage D runs vLLM on g304 (prefill) and g126 (decode) over the public internet path (29.7 ms RTT) — the actual cross-DC test.
- Stages 0a (transport bench, no GPU) and A (smoke on g126 alone) already work and don't need this ticket.

**What I won't do** (so this is low-risk):
- No changes to NVIDIA driver versions, kernel modules, or `/etc/nvidia*`.
- No changes to the K8s control plane.
- All workloads either run in containers (`nvidia-container-runtime`) or as `vpsupport` user processes on the host. Either way, the GPU Operator's driver stays in place.

**Time sensitivity:** Stage B/C/D plus 3-day repeats need ~1-2 weeks of cluster time. I'd like to have these unblocks within a week if possible.

**Reference:**
- Discovery report: `prfaas/docs/40-milestones/m1.5-vllm-baseline/discovery-REPORT.md` in
  https://github.com/HarshavardhanK/Mooncake/tree/feat/prfaas-m1.5-vllm-baseline
- Per-node JSON inventory: same directory.

Thanks!
