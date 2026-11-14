#!/usr/bin/env python3
"""Prove that the stardelt quickstart queries Trino as the signed-in hub user.

    HUB_URL=https://jupyter.alpha.dev.stardelt.io \
      NOTEBOOK_USER=analyst NOTEBOOK_PASSWORD=... \
      python3 scripts/verify-notebook-identity.py

What it does, in order:

  1. signs in at the hub the way a browser does (Keycloak login form, no API
     token, no direct-access grant) — with `auto_login` the hub then spawns the
     user's server itself;
  2. waits for the spawn the sign-in started (`auto_login` spawns it on the way
     back from the IdP) and, by default, stops and starts only a server that was
     already running before sign-in (`NOTEBOOK_RESTART=0` skips the restart) so
     the checks run against the image and auth_state the hub would give a new
     user, not against whatever was running. A spawn that is already in flight is
     never interrupted: JupyterHub then answers `400 … pending stop` and creates
     no pod for the follow-up start (platform#1252);
  3. runs the quickstart inside the pod with `jupyter nbconvert --execute` and
     expects it to succeed — the notebook itself asserts
     `SELECT current_user` equals the identity in the hub user's token;
  4. runs the same notebook with `TRINO_TOKEN` and the hub's `JUPYTERHUB_API_TOKEN` removed from
     the environment and expects a 401: the rows come from the user's own token, not from anything
     baked into the image, and with the hub token gone the library cannot mint one from `auth_state`.
  5. exits non-zero unless every check passed.

Environment:
  HUB_URL            hub base URL (default https://jupyter.alpha.dev.stardelt.io)
  NOTEBOOK_USER      hub user to prove (default analyst)
  NOTEBOOK_PASSWORD  that user's realm password (required)
  GROUP_PRINCIPAL    which claim Trino uses as the engine user (platform#311):
                     `sub` (default) — the Keycloak user id, the state after
                     `make catalog-enforce`; `username` — `preferred_username`,
                     the state before it. `SELECT current_user` is compared with
                     that claim from the pod's own `TRINO_TOKEN`, so the check
                     proves the engine used the person's token in the shape the
                     platform configured.
  NAMESPACE          Kubernetes namespace (default stardelt)
  NOTEBOOK           path inside the pod (default /opt/stardelt/notebooks/warehouse-quickstart.ipynb)
  NOTEBOOK_RESTART   stop/start before checking (default 1)
  NOTEBOOK_TIMEOUT   seconds to wait for the server (default 600; the first
                     spawn may pull a new image)
  NOTEBOOK_POD       pod name override; by default the pod is found through the
                     `hub.jupyter.org/username` label
  KUBECONFIG         inherited by kubectl

The default is the image's copy: the postStart hook seeds $HOME with cp -n, so a
home that already has the notebook keeps the version of the image that created
it. Pass NOTEBOOK to check a home copy deliberately.
"""
import base64
import http.cookiejar
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

HUB = os.environ.get("HUB_URL", "https://jupyter.alpha.dev.stardelt.io").rstrip("/")
USER = os.environ.get("NOTEBOOK_USER", "analyst")
PASSWORD = os.environ.get("NOTEBOOK_PASSWORD", "")
NAMESPACE = os.environ.get("NAMESPACE", "stardelt")
NOTEBOOK = os.environ.get("NOTEBOOK", "/opt/stardelt/notebooks/warehouse-quickstart.ipynb")
RESTART = os.environ.get("NOTEBOOK_RESTART", "1") not in ("0", "false", "no")
TIMEOUT = int(os.environ.get("NOTEBOOK_TIMEOUT", "600"))
PRINCIPAL = os.environ.get("GROUP_PRINCIPAL", "sub")

jar = http.cookiejar.CookieJar()
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))

FORM = re.compile(r"<form[^>]*>.*?</form>", re.S)
INPUT = re.compile(r'name="([^"]+)" value="([^"]*)"')
ACTION = re.compile(r'action="([^"]+)"')


def request(method, url, data=None):
    headers = {}
    if data is not None:
        data = urllib.parse.urlencode(data).encode()
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    xsrf = next((c.value for c in jar if c.name == "_xsrf"), None)
    if xsrf and method in ("POST", "DELETE"):
        # JupyterHub's API rejects cookie-authenticated writes without this.
        headers["X-XSRFToken"] = xsrf
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with opener.open(req, timeout=30) as resp:
            return resp.status, resp.geturl(), resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, url, e.read().decode("utf-8", "replace")


def only_form(url, html):
    match = FORM.search(html)
    if not match:
        sys.exit(f"verify-notebook-identity: no form on {url}: {html[:300]}")
    origin = urllib.parse.urlsplit(url)
    base = f"{origin.scheme}://{origin.netloc}"
    action = ACTION.search(match.group(0)).group(1).replace("&amp;", "&")
    return (base + action if action.startswith("/") else action), dict(INPUT.findall(match.group(0)))


def kubectl(*args, **kwargs):
    return subprocess.run(["kubectl", "-n", NAMESPACE, *args], text=True,
                          capture_output=True, **kwargs)


def token_claim(pod, name):
    """One claim from the pod's own TRINO_TOKEN, without verifying it.

    Trino verifies the token; this only answers "which string will Trino use as
    the engine user" — the `sub` or the `preferred_username`, depending on the
    platform's `principal-field` (platform#311). The token itself is never
    printed.
    """
    raw = kubectl("exec", pod, "--", "printenv", "TRINO_TOKEN").stdout.strip()
    if raw.count(".") != 2:
        sys.exit(f"verify-notebook-identity: no usable TRINO_TOKEN in pod {pod} "
                 "(the hub copies the signed-in user's token at spawn)")
    payload = raw.split(".")[1]
    payload += "=" * (-len(payload) % 4)
    return json.loads(base64.urlsafe_b64decode(payload)).get(name) or ""


def server_ready():
    status, _, body = request("GET", HUB + "/hub/api/user")
    if status != 200:
        return False
    servers = json.loads(body).get("servers") or {}
    return any(s.get("ready") for s in servers.values())


def wait_for(predicate, what, timeout=None):
    deadline = time.time() + (TIMEOUT if timeout is None else timeout)
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(2)
    return False


failures = []


def check(name, ok, detail=""):
    print(f"{'PASS' if ok else 'FAIL'}: {name}" + (f" — {detail}" if detail else ""))
    if not ok:
        failures.append(name)


# How long one retry of a restart waits, in seconds. A test sets it to 0.
RESTART_RETRY_SECONDS = 1


def server_state():
    """The signed-in user's server as the hub reports it: ready, pending or stopped."""
    status, _, body = request("GET", HUB + "/hub/api/user")
    if status != 200:
        return "unknown"
    for server in (json.loads(body).get("servers") or {}).values():
        if server.get("ready"):
            return "ready"
        if server.get("pending") or server.get("starting"):
            return "pending"
    return "stopped"


def ensure_fresh_server():
    """Make sure the checks run against a fresh spawn without wedging the spawner.

    With `auto_login` the sign-in already spawns the server. Interrupting that spawn
    (`DELETE` while it is pending) leaves JupyterHub answering `400 … pending stop` and
    no pod is ever created for the follow-up `POST` (platform#1252). So a spawn that is
    already in flight is waited for — it carries the current image and the new
    auth_state — and only a server that was running before sign-in is restarted.
    """
    state = server_state()
    if state == "pending":
        print("› 2/4 sign-in started the spawn (auto_login); waiting for it")
        return wait_for(server_ready, "server to become ready")
    if not RESTART:
        print("› 2/4 restart skipped (NOTEBOOK_RESTART=0)")
        return wait_for(server_ready, "server to become ready")
    print("› 2/4 restart the server (fresh spawn, fresh token)")
    request("DELETE", f"{HUB}/hub/api/users/{USER}/server")
    stopped = wait_for(lambda: server_state() == "stopped", "server to stop", timeout=120)
    check("server stopped", stopped)
    # The stop is asynchronous: a POST while the hub still answers "pending stop" is
    # refused and lost, so retry it for a bounded time.
    deadline = time.time() + 30
    while True:
        status, _, body = request("POST", f"{HUB}/hub/api/users/{USER}/server")
        if status in (200, 201, 202):
            break
        if "pending stop" not in body or time.time() >= deadline:
            check("server restarted", False, body.strip()[:200])
            return False
        time.sleep(RESTART_RETRY_SECONDS)
    return wait_for(server_ready, "server to become ready")


def main():
    if not PASSWORD:
        sys.exit("verify-notebook-identity: set NOTEBOOK_PASSWORD (the user's realm password)")

    # 1. Sign in like a browser: the hub redirects to Keycloak, we post the login
    #    form, and with auto_login the hub spawns the server on the way back.
    print(f"› 1/4 sign in at {HUB} as {USER}")
    status, url, html = request("GET", HUB + "/hub/login")
    if "id." in url and "form" not in html.lower():
        # A deployment where auto_login is off would show a button; say so instead
        # of failing with a confusing parse error.
        sys.exit(f"verify-notebook-identity: hub did not redirect to the IdP (final URL {url})")
    action, inputs = only_form(url, html)
    inputs.update({"username": USER, "password": PASSWORD, "credentialId": ""})
    status, url, html = request("POST", action, inputs)
    if "not allowed" in html.lower() or "not authorized" in html.lower():
        sys.exit(f"verify-notebook-identity: {USER} is not admitted by the hub "
                 "(allowed_groups in helm-values/jupyterhub.yaml gates on Keycloak groups)")
    if "/hub/" not in url and "/user/" not in url:
        sys.exit(f"verify-notebook-identity: sign-in did not return to the hub (at {url})")
    check("signed in", True)

    # 2. Wait for (or start) a spawn, without interrupting one already in flight.
    started = ensure_fresh_server()
    check("server ready", started)
    if not started:
        sys.exit("verify-notebook-identity: server never became ready; hub log is the next stop")

    # 3. Find the pod and run the quickstart inside it.
    pod = os.environ.get("NOTEBOOK_POD", "")
    if not pod:
        listing = kubectl("get", "pods", "-l", f"hub.jupyter.org/username={USER}",
                          "-o", "jsonpath={range .items[*]}{.metadata.name}{'\\n'}{end}")
        pods = [p for p in listing.stdout.split() if p]
        if not pods:
            sys.exit(f"verify-notebook-identity: no single-user pod for {USER} in {NAMESPACE}")
        pod = pods[-1]
    kubectl("wait", "--for=condition=Ready", f"pod/{pod}", f"--timeout={TIMEOUT}s")
    print(f"    pod: {pod}")

    # The engine user the platform configured (`principal-field`), read from the same
    # token the pod uses — no second source of truth for who this person is.
    if PRINCIPAL not in ("sub", "username"):
        sys.exit(f"verify-notebook-identity: GROUP_PRINCIPAL must be 'sub' or 'username', not {PRINCIPAL!r}")
    expected = token_claim(pod, "sub") if PRINCIPAL == "sub" else token_claim(pod, "preferred_username")
    if not expected:
        sys.exit(f"verify-notebook-identity: the token in pod {pod} carries no {PRINCIPAL!r} claim")

    nbconvert = ["jupyter", "nbconvert", "--to", "markdown", "--execute", "--stdout",
                 "--ExecutePreprocessor.timeout=300", NOTEBOOK]

    print("› 3/4 execute the quickstart with the hub user's token")
    positive = kubectl("exec", pod, "--", *nbconvert)
    output = positive.stdout
    print(output)
    check("quickstart executed", positive.returncode == 0,
          "" if positive.returncode == 0 else positive.stderr.strip()[-300:])
    check(f"Trino reports current_user = {expected} (the token's {PRINCIPAL})",
          "signed_in_as" in output and expected in output)
    # nbconvert's markdown template indents text outputs by four spaces, so match the
    # de-indented lines (measured on the demo pod, platform#1323).
    flattened = "\n".join(line.strip() for line in output.splitlines())
    check("the quickstart chose a catalog the person can see",
          re.search(r"^Catalog: (shared|playground)$", flattened, re.M) is not None)
    check("the quickstart wrote and read back its smoke table",
          "quickstart_smoke: 3 rows written and read back" in output)

    # 4. The negative: without the token there is nothing to authenticate with.
    print("› 4/4 execute the quickstart with TRINO_TOKEN and JUPYTERHUB_API_TOKEN unset (expect 401)")
    negative = kubectl("exec", pod, "--", "env", "-u", "TRINO_TOKEN", "-u", "JUPYTERHUB_API_TOKEN",
                       *nbconvert)
    failed = negative.returncode != 0
    refused = "401" in (negative.stdout + negative.stderr) or "Unauthorized" in (negative.stdout + negative.stderr)
    check("notebook fails without either token", failed)
    check("failure is a 401 from Trino", refused,
          "" if refused else (negative.stdout + negative.stderr).strip()[-300:])

    print()
    if failures:
        print(f"verify-notebook-identity: {len(failures)} check(s) failed: {', '.join(failures)}")
        return 1
    print("verify-notebook-identity: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
