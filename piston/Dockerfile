FROM ghcr.io/engineer-man/piston:latest

# Piston listens on 2000 by default.
EXPOSE 2000

# Patched entrypoint. Upstream moves only PID 1 out of the root cgroup before
# enabling subtree controllers, but Docker leaves additional processes
# (docker-init, shell) in the cgroup-ns-private root, so the subtree_control
# write fails with EBUSY. Our version moves every process and uses `mkdir -p`
# so restarts work without requiring --cgroupns=host.
COPY entrypoint.sh /piston_api/src/docker-entrypoint.sh
RUN chmod +x /piston_api/src/docker-entrypoint.sh
