FROM ghcr.io/engineer-man/piston:latest

# Piston listens on 2000 by default.
EXPOSE 2000

# --cgroupns=host makes /sys/fs/cgroup/isolate persist on the host across
# container restarts. Upstream's entrypoint does `mkdir isolate/` and fails
# when the dir already exists. Clean up first, then hand off to upstream.
ENTRYPOINT ["/bin/bash", "-c", "rmdir /sys/fs/cgroup/isolate/init 2>/dev/null; rmdir /sys/fs/cgroup/isolate 2>/dev/null; exec /piston_api/src/docker-entrypoint.sh"]
