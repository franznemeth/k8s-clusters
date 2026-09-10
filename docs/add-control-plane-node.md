# Promote `deimos.lan` + `pallas.lan` to control plane + etcd (lan: 1 → 3)

Goal: `ceres.lan` + `deimos.lan` + `pallas.lan` all run the API server and an
etcd member, so a single node/apiserver/etcd hiccup no longer drops every
controller's watches at once (the trigger behind the recurring Rook OSD
restart). `nas.lan` stays a plain worker.

This is a rollout **procedure**, not one playbook run. `inventory/hosts.yaml`
keeps `deimos`/`pallas` commented out of `kube_control_plane` and `etcd`; you
uncomment one node at a time as you reach its pass, so a stray full `cluster.yml`
never tries to promote an un-reset worker.

## Why it's the low-risk direction

- `ceres.lan` is never touched: still first in both groups, still the founding
  etcd member. No etcd data migration, no `cluster-info` surgery, no reorder.
- Purely additive: `kubeadm join --control-plane` for one node at a time. A
  failed join is undone with `remove-node.yml`; the working cluster is untouched.

## What still needs care

- **etcd 1 → 2 → 3.** While the count is even (2), losing either live member =
  quorum loss = API down (workloads keep running). Keep each pass short.
- **`deimos`/`pallas` are already `kube_node` members.** kubeadm can't promote a
  joined worker in place, so each is reset with `remove-node.yml` and rejoined.
  The reset drains the node → its Ceph mon + OSD go down for the reset + rejoin.
  **One node at a time**, `ceph -s` back to `HEALTH_OK` between them (2 of 3 OSDs
  stay up throughout). OSD data is on the dedicated SSD and is not wiped.
- **No control-plane taint.** `ceres.lan` has no taints today and runs Rook pods;
  the promoted nodes match that, so nothing is taint-evicted.
- **No VIP needed.** Every node's local `nginx-proxy` load-balances across the
  `kube_control_plane` list with automatic failover.
- `auto_renew_certificates_systemd_calendar` in `group_vars/all.yml` keys off the
  `kube_control_plane` group size — adapts to 3 nodes, no change.

All commands run from the repo root. `deploy.sh` adds `-b --private-key
~/.ssh/id_ed25519`; for Kubespray playbooks it `cd`s into `kubespray/`.

## 0. Prerequisite: LVM filter on every node

So a briefly-dropped OSD during the resets can't wedge on the `lvs` deadlock.

```sh
./deploy.sh inventory lvm-filter-rbd.yaml
```

## 1. Pre-flight

```sh
kubectl get nodes
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph -s        # HEALTH_OK, PGs active+clean

# etcd snapshot from the current sole member
ssh ceres.lan 'sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /root/etcd-$(date +%F).db && sudo ls -l /root/etcd-*.db'

# stop Ceph rebalancing while a node is briefly out
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd set noout
```

## 2. Pass A — `deimos.lan`

### 2a. Add it to the groups

In `inventory/hosts.yaml`, uncomment `deimos.lan` under **both**
`kube_control_plane` and `etcd`. Leave `pallas.lan` commented.

```sh
# fact cache for all hosts (required before a --limit run)
./deploy.sh inventory playbooks/facts.yml
```

### 2b. Reset the node

```sh
./deploy.sh inventory remove-node.yml -e node=deimos.lan -e skip_confirmation=yes
```

If the drain stalls on a Rook OSD PodDisruptionBudget, the cluster isn't fully
clean — wait for `ceph -s` to show all PGs `active+clean` and retry. Then:

```sh
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph -s        # HEALTH_OK again
```

### 2c. Rejoin as control plane + etcd + worker

```sh
./deploy.sh inventory cluster.yml \
  --limit=deimos.lan,ceres.lan \
  -e ignore_assert_errors=yes -e etcd_retries=10
```

Scope is only the new node + `ceres.lan` (the reference member) — `pallas.lan` is
still just a worker and must not be in scope. `ignore_assert_errors=yes` is for
the even etcd count.

### 2d. Verify before continuing

```sh
kubectl -n kube-system exec etcd-ceres.lan -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint health --cluster        # both endpoints healthy

for h in ceres.lan deimos.lan; do
  echo "== $h =="; ssh $h 'sudo grep -- --etcd-servers /etc/kubernetes/manifests/kube-apiserver.yaml'
done

kubectl get nodes                                                   # deimos.lan Ready, control-plane
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph -s         # HEALTH_OK
```

Do not start Pass B until `deimos.lan` is fully back and Ceph is healthy.

## 3. Pass B — `pallas.lan`

1. Uncomment `pallas.lan` under `kube_control_plane` and `etcd` in
   `inventory/hosts.yaml`.
2. `./deploy.sh inventory playbooks/facts.yml`
3. `./deploy.sh inventory remove-node.yml -e node=pallas.lan -e skip_confirmation=yes`
4. Wait for `ceph -s` → `HEALTH_OK`.
5. Rejoin, now with `deimos.lan` also in scope (it's a real control-plane node
   now, so its apiserver `--etcd-servers` needs `pallas` added):

   ```sh
   ./deploy.sh inventory cluster.yml \
     --limit=pallas.lan,ceres.lan,deimos.lan \
     -e etcd_retries=10
   ```

   No `ignore_assert_errors` — the count returns to odd (3).
6. Verify as in 2d, checking all three hosts.

## 4. Finish

```sh
# one reconcile pass across the whole control plane + etcd
./deploy.sh inventory upgrade-cluster.yml --limit=etcd,kube_control_plane

# reload the api LB on every node so it sees all three apiservers
kubectl -n kube-system delete pod -l k8s-app=kube-nginx

kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd unset noout

kubectl get nodes -o wide                                           # 3x control-plane
kubectl -n kube-system get pods -l component=etcd -o wide           # 3 etcd pods
kubectl -n kube-system exec etcd-ceres.lan -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  member list -w table                                              # 3 started members
```

Commit `inventory/hosts.yaml` with all three uncommented once it's done.

External access (`cluster-access.yaml`) still points at `ceres.lan` and keeps
working; regenerate with `./get-cluster-config.sh` only to retarget it.

## Rollback

A node's join failed or its etcd member is unhealthy:

```sh
./deploy.sh inventory remove-node.yml -e node=<node> -e skip_confirmation=yes
```

Re-comment it in `inventory/hosts.yaml`. The remaining members keep quorum. If
`ceres.lan` itself was damaged, restore `/root/etcd-<date>.db` with
`etcdctl snapshot restore` and `kubespray/recover-control-plane.yml`.
