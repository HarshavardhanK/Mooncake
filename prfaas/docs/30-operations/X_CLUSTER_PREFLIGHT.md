# X cluster pre-flight for Phase 3 cross-DC

Concrete checks the operator runs **before** applying anything in
`prfaas/m1.5-vllm-baseline/k8s/phase3-xdc/x/`. Every step here is
read-only on the host (kubectl `get`, `describe`, plus an SSH-side
`iptables -S | grep`). Nothing here changes cluster state.

If any check fails, **stop**, fix it, then re-run from the top. Skipping
a failed check makes the cross-DC smoke (`y/90-smoke-job.yaml`) fail in
ways that look like SGLang bugs but are actually plumbing.

> Counterpart on Y is light enough that it lives inline in
> [`XDC_RUNBOOK.md`](XDC_RUNBOOK.md) §pre-flight. This doc is X-only.

## 1. Cluster context

```bash
kubectl config get-contexts | grep -E '(NAME|prfaas|g304)'
```

You should see the X cluster context (typically named after the X
management cluster — see Stage D's notes for the exact name on your
workstation). Set it for convenience:

```bash
export KCTX_X="<your-X-context>"
kubectl --context "${KCTX_X}" get nodes
```

Expect `g304` and `g307` to be `Ready`. **Action if g304 is `NotReady`:**
escalate to the X cluster operator; do not proceed.

## 2. Namespace + RBAC

```bash
kubectl --context "${KCTX_X}" get ns prfaas-staged
kubectl --context "${KCTX_X}" -n prfaas-staged auth can-i create deploy --as=system:serviceaccount:prfaas-staged:default
kubectl --context "${KCTX_X}" -n prfaas-staged auth can-i create job
kubectl --context "${KCTX_X}" -n prfaas-staged auth can-i create configmap
```

All three should print `yes`. If `prfaas-staged` does not exist yet,
applying `x/00-configmap.yaml` creates it (the manifest carries a
Namespace object); RBAC must already be in place from Stage D.

**Action if RBAC is missing:** ask the X cluster operator to apply Stage
D's RoleBinding (it grants `system:serviceaccount:prfaas-staged:default`
the equivalent of `mks:customer` inside `prfaas-staged`).

## 3. GPU capacity on g304

```bash
kubectl --context "${KCTX_X}" describe node g304 | grep -E 'Allocatable|nvidia.com/gpu|Taints'
```

Expect:

```
Allocatable:
  ...
  nvidia.com/gpu:    8
Taints:             <none>   # or: voltagepark.io/cni-pending=true:NoSchedule (tolerated)
```

If `nvidia.com/gpu` is missing or `0`, the GPU operator's validation has
not finished. **Action:** check `kubectl --context "${KCTX_X}" -n
gpu-operator get pods -o wide --field-selector spec.nodeName=g304`.

## 4. Public IP + Stage 0a path health

The decoder on Y dials `159.26.81.50:8998` over the WAN. We sanity-check
the path is still what Stage 0a measured:

```bash
# From any host with WAN reach to g304 (e.g. your workstation):
nc -zv 159.26.81.50 8998 || echo "8998 not yet open (expected pre-firewall)"
ping -c 5 -i 0.2 159.26.81.50
```

Expected RTT ≈ Stage 0a baseline (29.75 ms). Spikes > 50 ms or packet
loss should be flagged before continuing — they will dominate the
cross-DC TTFT and make the headline number unreproducible.

## 5. Existing firewall rules

`ssh vpsupport@159.26.81.50 sudo iptables -S INPUT | grep -E '147.185.40.126|prfaas'`

You should see (from Stage 0a + Stage D):

```
-A INPUT -p tcp -s 147.185.40.126/32 --dport 8998 -j ACCEPT
-A INPUT -p tcp -s 147.185.40.126/32 --dport 13000:17000 -j ACCEPT
```

If 8998 is missing, Stage D's firewall script was never run. **Action:**
proceed to step 6 — Phase 3's firewall script is idempotent and re-adds
8998 if needed.

## 6. Apply the Phase 3 firewall extension

`firewall/g304-phase3-iptables.sh` adds **TCP 30001 from 147.185.40.126/32**
(the SGLang API port the router on Y dials). It is idempotent and reuses
Stage D's 8998 rule.

```bash
scp prfaas/m1.5-vllm-baseline/k8s/phase3-xdc/firewall/g304-phase3-iptables.sh \
    vpsupport@159.26.81.50:/tmp/
ssh vpsupport@159.26.81.50 'sudo bash /tmp/g304-phase3-iptables.sh'
```

After it runs, re-check:

```bash
ssh vpsupport@159.26.81.50 sudo iptables -S INPUT | grep -E '147.185.40.126|prfaas'
```

You should see **three** lines (8998, 30001, 13000:17000).

## 7. Disk space on g304's /scratch

The model staging Job writes ~49 GiB to `/scratch/models/...`. Confirm
there is room:

```bash
ssh vpsupport@159.26.81.50 'df -h /scratch'
```

Expect at least **80 GiB free** (49 GiB model + headroom for the HF
tempfiles during download). If short, free old caches under
`/scratch/models` first.

## 8. Image pull cache (optional but speeds first apply)

The SGLang image is ~9 GiB. If g304 has not pulled it before, the
Deployment will spend 5-15 minutes pulling on first apply. Pre-pull:

```bash
ssh vpsupport@159.26.81.50 'sudo crictl pull lmsysorg/sglang:v0.5.9-cu129-amd64'
```

(Use `docker pull` instead if g304 still uses dockerd.)

## 9. Pre-flight done

You are clear to apply the X-side staging Job. Continue with
[`XDC_RUNBOOK.md`](XDC_RUNBOOK.md) §1.
