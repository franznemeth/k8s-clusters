#!/bin/bash

git submodule update --init --remote --recursive
virtualenv -p python3 venv
. venv/bin/activate
pip3 install -U -r kubespray/requirements.txt
ansible --version

# Galaxy roles used by roles/base (installed into ./roles, gitignored there).
ansible-galaxy install -r requirements.yml -p roles/
