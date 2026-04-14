# Dokku and Socket.io Websockets

Dokku's default nginx template (`nginx-vhosts` plugin, v0.24+) sets
`proxy_http_version 1.1` and the `Upgrade`/`Connection` headers needed for
websockets. No custom nginx config is required for Socket.io to work.

If you hit "websocket connection failed" in the browser, check:

```bash
dokku nginx:show-config interview-server
```

and look for `Upgrade` handling. If missing, bump the nginx-vhosts plugin.
