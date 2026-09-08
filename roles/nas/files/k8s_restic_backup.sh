#!/bin/bash
#: Title              : restic-rancher
#: Author             : Franz Nemeth
#: Version            : 0.1
#: Description        : Run restic backup for rancher persistent data

# /etc/backup_credentials has to contain the following lines
#export AWS_ACCESS_KEY_ID=
#export AWS_SECRET_ACCESS_KEY=
#export RESTIC_PASSWORD=
#export RESTIC_REPOSITORY=s3:https://someurl.foo/bucket
source /etc/backup_credentials

# run command
set +e
restic backup /mnt/Storage/kubernetes/pvc --verbose --tag lan-rancher-data | tee -a /var/log/backup.log

echo "pruning old snapshots"
restic forget --verbose --keep-daily 7 --keep-weekly 4 --keep-monthly 12 --keep-yearly 1 --prune | tee -a /var/log/backup.log