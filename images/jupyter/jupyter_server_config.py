"""stardelt's additions to Jupyter Server, for every spawned single-user server.

Installed as /usr/local/etc/jupyter/jupyter_server_config.py. Jupyter Server
loads one config file per config path, and /usr/local/etc/jupyter is a path
(and outranks the base image's /etc/jupyter copy), so this file runs for any
app in the image — JupyterHub's `jupyterhub-singleuser` included.

Framing. A single-user server executes arbitrary code, so JupyterHub's
single-user app pins its Content-Security-Policy to `frame-ancestors 'none'`
unless something already set the header (jupyterhub/singleuser/mixins.py,
`init_webapp`). stardelt's Nova embeds the hub, and the hub sends a signed-in
person on to this server, so this server allows Nova's own origin — and nothing
else. The origin is not baked into the image: the hub passes
STARDELT_NOVA_ORIGIN at spawn, read from the platform identity contract's
`publicUrl` (helm-values/jupyterhub.yaml, extraConfig `15-framing`). Without an
identity there is no origin, this file changes nothing, and the secure
`'none'` default stands.
"""
import os

c = get_config()  # noqa: F821

_nova_origin = os.environ.get("STARDELT_NOVA_ORIGIN", "").rstrip("/")
if _nova_origin:
    c.ServerApp.tornado_settings = {
        "headers": {
            "Content-Security-Policy": f"frame-ancestors 'self' {_nova_origin}",
        }
    }

# VS Code in the browser through the hub's own proxy (stardelt-platform#158).
# code-server listens on the pod's loopback only and is started by
# jupyter-server-proxy on first use; the hub session is the only authentication,
# so code-server's own password is off. The launcher tile is the whole UI: there
# is no second ingress and no second login.
c.ServerProxy.servers = {
    "vscode": {
        "command": [
            "code-server",
            "--auth", "none",
            "--bind-addr", "127.0.0.1:{port}",
            "--disable-telemetry",
            "--disable-update-check",
        ],
        # One code-server per single-user pod, so a fixed port is safe and makes
        # the proxied port predictable. The path a browser uses is the server
        # NAME, not the port: `/vscode/` (jupyter-server-proxy 4.6 mounts each
        # configured server at `/<name>/`; `/proxy/8899/` is the generic
        # local-port proxy, which forwards but never starts the process).
        "port": 8899,
        "timeout": 30,
        "launcher_entry": {"title": "VS Code", "enabled": True},
    }
}
