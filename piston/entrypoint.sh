#!/bin/bash
set -e

CGROUP_FS="/sys/fs/cgroup"

if [ ! -e "$CGROUP_FS/cgroup.subtree_control" ]; then
  echo "Cgroup v2 not found. Please make sure cgroup v2 is enabled on your system"
  exit 1
fi

cd "$CGROUP_FS"

# Ensure the isolate/ and isolate/init cgroups exist (mkdir -p so restarts
# don't fail).
mkdir -p isolate
mkdir -p isolate/init

# Move every process currently in the namespace-root cgroup into isolate/,
# so cgroup.subtree_control can be written (v2 refuses if non-empty).
for pid in $(cat cgroup.procs); do
  echo "$pid" > isolate/cgroup.procs 2>/dev/null || true
done

echo '+cpuset +cpu +io +memory +pids' > cgroup.subtree_control

cd isolate

# Same trick for the isolate/init subgroup.
for pid in $(cat cgroup.procs); do
  echo "$pid" > init/cgroup.procs 2>/dev/null || true
done

echo '+cpuset +memory' > cgroup.subtree_control

echo "Initialized cgroup"

chown -R piston:piston /piston

exec su -- piston -c 'ulimit -n 65536 && node /piston_api/src'
