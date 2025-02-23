#!/bin/bash

# Switching to the script directory.
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
cd $SCRIPT_DIR

# Configuring custom settings for nodes.
#ansible-playbook -i ./inventory ./playbooks/hosts-custom-configuration.yaml

# Deploying Kubernetes to nodes.
cd kubespray && ansible-playbook -i ../$1 ./$2 -b --private-key ~/.ssh/id_ed25519 #-vvv
