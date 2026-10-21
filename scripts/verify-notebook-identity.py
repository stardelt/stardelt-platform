#!/usr/bin/env python3
"""Prove that the stardelt quickstart queries Trino as the signed-in hub user.

    HUB_URL=https://jupyter.alpha.dev.stardelt.io \
      NOTEBOOK_USER=analyst NOTEBOOK_PASSWORD=... \
      python3 scripts/verify-notebook-identity.py

What it does, in order:

  1. signs in at the hub the way a browser does (Keycloak login form, no API
     token, no direct-access grant) — with `auto_login` the hub then spawns the
     user's server itself;
  2. by default stops and starts the server (`NOTEBOOK_RESTART=0` skips it) so
     the checks run against the image and auth_state the hub would give a new
     user, not against whatever was running;
  3. runs the quickstart inside the pod with `jupyter nbconvert --execute` and
     expects it to succeed — the notebook itself asserts
     `SELECT current_user` equals the hub user;
  4. runs the same notebook with `TRINO_TOKEN` removed from the environment and
     expects a 401: the rows come from the user's own token, not from anything
     baked into the image;
  5. exits non-zero unless every check passed.

Environment:
  HUB_URL            hub base URL (default https://jupyter.alpha.dev.stardelt.io)
  NOTEBOOK_USER      hub user to prove (default analyst)
  NOTEBOOK_PASSWORD  that user's realm password (required)
  NAMESPACE          Kubernetes namespace (default stardelt)
  NOTEBOOK           path inside the pod (default /home/jovyan/warehouse-quickstart.ipynb)
  NOTEBOOK_RESTART   stop/start before checking (default 1)
  NOTEBOOK_TIMEOUT   seconds to wait for the server (default 600; the first
                     spawn may pull a new image)
  NOTEBOOK_POD       pod name override; by default the pod is found through the
                     `hub.jupyter.org/username` label
  KUBECONFIG         inherited by kubectl
"""
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
NOTEBOOK = os.environ.get("NOTEBOOK", "/home/jovyan/warehouse-quickstart.ipynb")
RESTART = os.environ.get("NOTEBOOK_RESTART", "1") not in ("0", "false", "no")
TIMEOUT = int(os.environ.get("NOTEBOOK_TIMEOUT", "600"))

if not PASSWORD:
    sys.exit("verify-notebook-identity: set NOTEBOOK_PASSWORD (the user's realm password)")

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

# 2. Optionally restart so the current image and auth_state are what we test.
if RESTART:
    print("› 2/4 restart the server (fresh spawn, fresh token)")
    request("DELETE", f"{HUB}/hub/api/users/{USER}/server")
    stopped = wait_for(lambda: not server_ready(), "server to stop", timeout=120)
    check("server stopped", stopped)
    request("POST", f"{HUB}/hub/api/users/{USER}/server")
else:
    print("› 2/4 restart skipped (NOTEBOOK_RESTART=0)")

started = wait_for(server_ready, "server to become ready")
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

nbconvert = ["jupyter", "nbconvert", "--to", "markdown", "--execute", "--stdout",
             "--ExecutePreprocessor.timeout=300", NOTEBOOK]

print("› 3/4 execute the quickstart with the hub user's token")
positive = kubectl("exec", pod, "--", *nbconvert)
output = positive.stdout
print(output)
check("quickstart executed", positive.returncode == 0,
      "" if positive.returncode == 0 else positive.stderr.strip()[-300:])
check(f"Trino reports current_user = {USER}", f"signed_in_as" in output and USER in output)
check("warehouse.covid.covid_summary was queried", "warehouse.covid.covid_summary" in output)

# 4. The negative: without the token there is nothing to authenticate with.
print("› 4/4 execute the quickstart with TRINO_TOKEN unset (expect 401)")
negative = kubectl("exec", pod, "--", "env", "-u", "TRINO_TOKEN", *nbconvert)
failed = negative.returncode != 0
refused = "401" in (negative.stdout + negative.stderr) or "Unauthorized" in (negative.stdout + negative.stderr)
check("notebook fails without TRINO_TOKEN", failed)
check("failure is a 401 from Trino", refused,
      "" if refused else (negative.stdout + negative.stderr).strip()[-300:])

print()
if failures:
    print(f"verify-notebook-identity: {len(failures)} check(s) failed: {', '.join(failures)}")
    sys.exit(1)
print("verify-notebook-identity: all checks passed")
