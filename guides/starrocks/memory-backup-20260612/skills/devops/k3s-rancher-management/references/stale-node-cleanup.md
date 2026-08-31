# K3s Stale Node Cleanup After Hostname Rename

## Scenario

A K3s node was running under hostname `cluster1`. The host was renamed to `k3s-luban` and `systemctl start k3s` was run again. The systemd service creates a new control-plane node with the new hostname, but the old `cluster1` node entry persists in the datastore.

## Detecting a Stale Node

```bash
k3s kubectl get nodes -o wide
```
The old node shows:
- `STATUS`: may show as `NotReady` or `Unknown`
- `AGE`: days or months old
- Same `INTERNAL-IP` as the new node (same host)

```bash
k3s kubectl describe node <old-node>
```
All condition types show `Unknown` with `Kubelet stopped posting node status`.
The `LastHeartbeatTime` is hours or days in the past.

## Removing the Stale Node

```bash
k3s kubectl delete node <old-node>
```

## Effects

- Pods running on the deleted node go `Terminating` and get rescheduled to remaining nodes
- The rancher-webhook and cattle-cluster-agent redeploy automatically via their Deployments
- Give 30-60 seconds for the new pods to become `Running` on the active node
- `kubectl get nodes` now shows only the active node(s)

## Verification

```bash
# Check nodes
k3s kubectl get nodes

# Check rescheduled pods
k3s kubectl get pods -n cattle-system -o wide
# Both cattle-cluster-agent and rancher-webhook should be Running on the active node
```
