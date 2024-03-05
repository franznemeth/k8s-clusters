#!/bin/bash

git submodule update --init --remote --recursive
virtualenv -p python3 venv
. venv/bin/activate
pip3 install -U -r kubespray/requirements.txt
ansible --version