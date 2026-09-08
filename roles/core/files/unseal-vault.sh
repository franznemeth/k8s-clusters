#!/bin/bash

ctrid=$(crictl ps | grep vault | awk '{print $1}')

if crictl exec $ctrid vault status --format=json; then
  echo "Vault is not sealed..."
  exit 0
else
        echo "Vault is sealed"
        crictl exec $ctrid vault operator unseal URqct2tOr7WOgl/N88rKrXH+ZhYIjSwniR/o4lHZhHI=
fi