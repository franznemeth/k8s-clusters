# k8s-clusters

Ansible for the `lan` and `core` home clusters. Two layers, one entrypoint
(`deploy.sh`):

1. **Host configuration** — `playbooks/site.yml` + `roles/` (folded in from the
   old `ansible-lan` repo): packages, SSH keys, sudo, timezone, sysctls,
   `dynmotd`, an LVM `global_filter` that excludes Ceph RBD devices, plus the
   `nas` role (ZFS / Samba / restic / zfs-exporter on `nas.lan`) and the `core`
   role (Vault auto-unseal timer on `core.lan`).
2. **Cluster lifecycle** — Kubespray, vendored as a git submodule under
   `kubespray/`.

## Layout

| Path                 | What                                                                    |
| -------------------- | -------------------------------------------------------------------- |
| `kubespray/`         | Kubespray submodule (currently v2.31.0)                             |
| `inventory/`         | `lan` cluster: `hosts.yaml` + `group_vars/all.yml`                 |
| `inventory-core/`    | `core` cluster inventory                                           |
| `roles/`             | `base`, `nas`, `core`, `gpu` host-config roles (Galaxy roles land here too, gitignored) |
| `playbooks/site.yml` | Host-config play — `base` on all nodes, `nas` on the `nas` group, `gpu` on the `gpu` group, `core` on the `vault` group |
| `playbooks/`         | Also holds targeted one-off plays (`lvm-filter-rbd.yaml`, `download-cluster-config.yaml`, ...) |
| `manifests/`         | Bootstrap-only Cilium manifests — see [New cluster](#provisioning-a-new-cluster) |
| `docs/`              | Operational runbooks                                               |
| `requirements.yml`   | Galaxy roles (`gantsign.oh-my-zsh`, `linux-system-roles.cockpit`) |
| `ansible.cfg`        | Config for the repo-root host-config runs (Kubespray uses its own) |
| `*.sh`               | Wrappers — see below                                              |

`inventory*/artifacts/` and `inventory*/credentials/` are gitignored.

## Usage

```bash
./init.sh                                    # submodule + venv + pip + galaxy roles

# Host configuration
./deploy.sh inventory      site.yml          # lan  nodes (base; nas role on nas.lan)
./deploy.sh inventory-core site.yml          # core node (base + Vault unseal; prompts for vault pass)
./deploy.sh inventory      lvm-filter-rbd.yaml   # just the LVM global_filter task, all hosts

# Cluster lifecycle (Kubespray)
./deploy.sh inventory      cluster.yml
./deploy.sh inventory      upgrade-cluster.yml --limit=etcd,kube_control_plane
```

`deploy.sh <inventory> <playbook>` resolves `<playbook>` to `playbooks/<playbook>`
(host config, run from the repo root) if it exists, otherwise to
`kubespray/<playbook>`. Extra args pass straight through to `ansible-playbook`.

### Disruptive base tasks are opt-in

`roles/base` can do a full `dnf upgrade "*"` + reboot-if-needed. It is **off by
default** so a `site.yml` run is safe against the live cluster. Enable per node,
in a maintenance window:

```bash
./deploy.sh inventory site.yml --limit deimos.lan -e base_full_upgrade=true
```

`firewalld` is stopped and masked **by default** (`base_manage_firewalld: true`):
cluster nodes run without it, and a fresh EL install leaves it rejecting kubelet
(10250) and Cilium traffic. A no-op on nodes where it is already masked.

### LVM filter for the Rook OSD restart deadlock

`roles/base` sets `devices/global_filter` in `/etc/lvm/lvm.conf` to reject
`/dev/rbd*` and `/dev/nbd*`, so host `lvs`/`pvscan` don't hang on I/O-blocked
Ceph devices while the cluster is degraded. (CephFS is a kernel network mount
with no block device — nothing to filter.) This hardens *host* LVM only; it does
not reach the `lvs` inside the Rook OSD `activate` container. Applied by every
`site.yml` run, or on its own via `playbooks/lvm-filter-rbd.yaml`.

## Provisioning a new cluster

Cilium is owned by ArgoCD (`k8s-deployments`: `deployments/<cluster>/cilium`),
so both inventories run Kubespray with `kube_network_plugin: cni` — Kubespray
installs only the CNI plugin binaries and never touches the Cilium objects.

That leaves a fresh cluster with **no CNI** (nodes stay `NotReady`, ArgoCD
cannot start). For the very first `cluster.yml` of a new cluster only:

1. Refresh `manifests/cilium*.yaml` to the Cilium version ArgoCD will run
   (`helm template` of the `k8s-deployments` chart) — they are pinned to the
   original v1.15.6 bootstrap.
2. In the new inventory set, temporarily:
   ```yaml
   kube_network_plugin: custom_cni
   custom_cni_manifests:
     - "{{ playbook_dir }}/../../manifests/<cluster>.yaml"
   ```
3. Run `cluster.yml`, bootstrap ArgoCD, let it adopt Cilium.
4. **Switch back to `kube_network_plugin: cni` and drop `custom_cni_manifests`
   before any further Kubespray run.**

Why step 4 matters: with `custom_cni`, every `cluster.yml` / `scale.yml` /
`upgrade-cluster.yml` re-applies the manifest. On 2026-11-13 that rolled the lan
Cilium DaemonSet from 1.20.4 back to 1.15.6 (then ArgoCD forward again) twice;
the cluster-wide Cilium churn broke OSD heartbeats and pod networking, took
Ceph down via the rbd/`activate` deadlock above, and left pods created during
the flip without a CiliumEndpoint (no network until recreated).

## Runbooks

- [`docs/add-control-plane-node.md`](docs/add-control-plane-node.md) — promote
  `deimos.lan` / `pallas.lan` to control plane + etcd (1 → 3 HA). The inventory
  already lists them; the rollout is a deliberate, one-node-at-a-time operation.

## Troubleshooting

If a Kubespray run fails with a `kubernetes.core` collection exception:

```bash
ansible-galaxy collection install kubernetes.core --upgrade
```
