#!/bin/bash
#
# One entrypoint for both layers of this repo:
#
#   ./deploy.sh <inventory> <playbook> [extra ansible-playbook args...]
#
# <playbook> is resolved in this order:
#   1. playbooks/<playbook>      -> host configuration (roles/ tree), run from
#                                   the repo root so ansible.cfg + roles_path
#                                   apply. Prompts for the vault password when
#                                   any roles/ var file is encrypted.
#   2. <playbook> (repo root)    -> other local playbooks as-is
#   3. kubespray/<playbook>      -> cluster lifecycle (Kubespray), run from
#                                   kubespray/ so its own ansible.cfg wins
#
# Examples:
#   ./deploy.sh inventory      site.yml                       # lan host config
#   ./deploy.sh inventory-core site.yml                       # core host config + Vault unseal
#   ./deploy.sh inventory      site.yml --limit deimos.lan -e base_full_upgrade=true
#   ./deploy.sh inventory      cluster.yml                    # Kubespray
#   ./deploy.sh inventory      upgrade-cluster.yml --limit=etcd,kube_control_plane

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
cd "$SCRIPT_DIR"

if [ "$#" -lt 2 ]; then
  sed -n '2,24p' "$0"
  exit 1
fi

INVENTORY="$1"
PLAYBOOK="$2"
shift 2
KEY="$HOME/.ssh/id_ed25519"

if [ -f "$SCRIPT_DIR/playbooks/$PLAYBOOK" ]; then
  ASK_VAULT=""
  if grep -rlq 'ANSIBLE_VAULT' "$SCRIPT_DIR/roles" 2>/dev/null; then
    ASK_VAULT="--ask-vault-pass"
  fi
  exec ansible-playbook -i "$INVENTORY" "playbooks/$PLAYBOOK" \
    -b --private-key "$KEY" $ASK_VAULT "$@"
elif [ -f "$SCRIPT_DIR/$PLAYBOOK" ]; then
  exec ansible-playbook -i "$INVENTORY" "$PLAYBOOK" -b --private-key "$KEY" "$@"
else
  cd kubespray
  exec ansible-playbook -i "../$INVENTORY" "$PLAYBOOK" -b --private-key "$KEY" "$@"
fi
