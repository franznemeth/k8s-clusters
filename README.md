# k8s-clusters

Ansible for the `lan` and `core` home clusters. Two layers, one entrypoint:

1. **Host configuration** — `playbooks/site.yml` + `roles/` (ported from the old
   `ansible-lan` repo): packages, SSH keys, sudo, timezone, sysctls, `dynmotd`,
   plus the `nas` role (ZFS / Samba / restic / zfs-exporter on `nas.lan`) and the
   `core` role (Vault auto-unseal timer on `core.lan`).
2. **Cluster lifecycle** — Kubespray, vendored as a git submodule under
   `kubespray/`.

## Layout

| Path                | What                                                                     |
| ------------------- | ---------------------------------------------------------------------- |
| `kubespray/`        | Kubespray submodule (currently v2.31.0)                               |
| `inventory/`        | `lan` cluster: `hosts.yaml` + `group_vars/all.yml`                   |
| `inventory-core/`   | `core` cluster inventory                                             |
| `roles/`            | `base`, `nas`, `core` host-config roles (Galaxy roles land here too, gitignored) |
| `playbooks/site.yml`| Host-config play — `base` on all nodes, `nas` on the `nas` group, `core` on the `vault` group |
| `manifests/`        | Static Cilium manifests (`custom_cni_manifests`)                     |
| `requirements.yml`  | Galaxy roles (`gantsign.oh-my-zsh`, `linux-system-roles.cockpit`)   |
| `ansible.cfg`       | Config for the repo-root host-config runs (Kubespray uses its own)  |
| `*.sh`              | Wrappers — see below                                                |

`inventory*/artifacts/` and `inventory*/credentials/` are gitignored.

## Usage

```bash
./init.sh                                    # submodule + venv + pip + galaxy roles

# Host configuration
./deploy.sh inventory      site.yml          # lan  nodes (base; nas role on nas.lan)
./deploy.sh inventory-core site.yml          # core node (base + Vault unseal; prompts for vault pass)

# Cluster lifecycle (Kubespray)
./deploy.sh inventory      cluster.yml
./deploy.sh inventory      upgrade-cluster.yml --limit=etcd,kube_control_plane
```

`deploy.sh <inventory> <playbook>` resolves `<playbook>` to `playbooks/<playbook>`
(host config, run from repo root) if it exists, otherwise to
`kubespray/<playbook>`. Extra args are passed straight through to
`ansible-playbook`.

### Disruptive base tasks are opt-in

`roles/base` can do a full `dnf upgrade "*"` + reboot-if-needed, and can mask
`firewalld`. Both are **off by default** so a `site.yml` run is safe against the
live cluster. Enable per node, in a maintenance window:

```bash
./deploy.sh inventory site.yml --limit deimos.lan -e base_full_upgrade=true
```

## Troubleshooting

If a Kubespray run fails with a `kubernetes.core` collection exception:

```bash
ansible-galaxy collection install kubernetes.core --upgrade
```
