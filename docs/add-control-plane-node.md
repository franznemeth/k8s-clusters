# Promoting worker nodes to control plane (lan cluster: 1 → 3)

Goal: make `deimos.lan` and `pallas.lan` control-plane + etcd members alongside
`ceres.lan`, so a single node/apiserver/etcd hiccup no longer takes the whole
cluster down (this is the trigger behind the recurring Rook OSD deadlock — see
the memory note / `k8s-deployments` incident history).

The inventory change on this branch (`feat/promote-control-plane`) is only the
end state. **Do not merge and run `cluster.yml` casually** — `deimos.lan` and
`pallas.lan` are already `kube_node` members and both run a Ceph mon + OSD, so
they must be added **one at a time** with Ceph health checks between them.

## Constraints

- **Odd etcd count.** Going 1 → 3 transits through 2 members. During that window,
  losing either of the two live members = etcd quorum loss = API down. Keep it
  short and do not reboot anything else meanwhile.
- **First entry is fixed.** `ceres.lan` must stay first in `kube_control_plane`
  and `etcd`. Kubespray cannot change the first entry.
- **etcd is kubeadm-managed** (`etcd_deployment_type: kubeadm`) and co-located
  with the API server on each control-plane node.
- **etcd shares disks with Ceph OSDs.** etcd is fsync-heavy; OSD I/O spikes will
  raise etcd fsync latency. If possible, first move etcd to its own device by
  setting `etcd_data_dir` (group_vars) to a path on a separate disk. Otherwise
  expect the two to compete.
- No API VIP — each node runs a local `nginx-proxy` static pod that load-balances
  to the `kube_control_plane` list. It must be restarted on every node after the
  membership changes.

## Pre-flight

```sh
# Cluster + Ceph healthy, all PGs active+clean
kubectl get nodes
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph -s     # HEALTH_OK

# Back up etcd from the current sole control-plane node
ssh ceres.lan 'sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /root/etcd-$(date +%F).db'

# Refresh the Ansible fact cache (required before any --limit run)
cd ~/git/k8s-clusters/kubespray
ansible-playbook -i ../inventory playbooks/facts.yml -b --private-key ~/.ssh/id_ed25519
```

Optionally set `noout` so Ceph doesn't rebalance while a node is briefly reset:

```sh
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd set noout
```

## Procedure — repeat for deimos.lan, then pallas.lan

Work on **one** node at a time. `<node>` = `deimos.lan` first, then `pallas.lan`.

### 1. Drain and reset the node as a plain worker

Because it is already a `kube_node`, remove it before re-adding it as
control-plane + etcd (Kubespray's supported path for adding an existing worker to
`etcd`). This wipes k8s from the node, so its mon + OSD go down for the duration.

```sh
cd ~/git/k8s-clusters/kubespray
ansible-playbook -i ../inventory remove-node.yml \
  -b --private-key ~/.ssh/id_ed25519 -e node=<node>
```

Wait for Ceph to settle back to `HEALTH_OK` / all PGs `active+clean` (2 of 3 OSDs
must stay up the whole time — that's why this is one node at a time):

```sh
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph -s
```

### 2. Re-add it as control-plane + etcd + worker

The inventory on this branch already lists `<node>` in all three groups.

```sh
ansible-playbook -i ../inventory cluster.yml \
  -b --private-key ~/.ssh/id_ed25519 \
  --limit=etcd,kube_control_plane \
  -e ignore_assert_errors=yes -e etcd_retries=10
```

`ignore_assert_errors=yes` is needed while the etcd count is even.

### 3. Propagate etcd config to all control-plane nodes

```sh
ansible-playbook -i ../inventory upgrade-cluster.yml \
  -b --private-key ~/.ssh/id_ed25519 \
  --limit=etcd,kube_control_plane \
  -e ignore_assert_errors=yes
```

### 4. Verify etcd membership and API server config

```sh
# New member should be present and started
ssh ceres.lan 'sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  member list -w table'

# --etcd-servers must list every etcd node on every control-plane host
for h in ceres.lan deimos.lan pallas.lan; do
  ssh $h 'sudo grep -- --etcd-servers /etc/kubernetes/manifests/kube-apiserver.yaml'
done
```

If a control-plane node's `--etcd-servers` is missing the new endpoint, add it by
hand and let the static pod restart.

### 5. Restart nginx-proxy on every node

```sh
kubectl -n kube-system delete pod -l k8s-app=kube-nginx   # label may be 'nginx-proxy'; check
```

Then confirm the new node is `Ready` and shows `control-plane` in `ROLES`, its mon
rejoined quorum, and its OSD is back `up`:

```sh
kubectl get nodes
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph -s
```

Only then move on to the second node.

## Post

```sh
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd unset noout   # if set

# Final state: 3x control-plane, 3 etcd members, HEALTH_OK
kubectl get nodes -o wide
```

The `auto_renew_certificates_systemd_calendar` stagger in `group_vars/all.yml`
already keys off `groups['kube_control_plane'].index(...)`, so it adapts to 3
nodes with no change.

## Rollback

If etcd is unhealthy after step 2 for a node, `remove-node.yml -e node=<node>`
that node again, restore quorum on the remaining members, and if needed restore
`ceres.lan` from the snapshot with `etcdctl snapshot restore` +
`recover-control-plane.yml`.
