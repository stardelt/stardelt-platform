#!/usr/bin/env python3
"""Mint a real Keycloak access token for one user through the OAuth2 device
grant (client `trino`) and prove Trino authenticates it as that user.

Called by scripts/verify-trino-auth.sh, which provides:

    ISSUER           https://id.<baseDomain>/realms/stardelt
    TRINO_URL        public Trino origin, e.g. https://trino.<baseDomain>
    USER, PASSWORD   the realm user to prove
    CLIENT_SECRET_FILE   file holding the `trino` client secret (never argv)

Exits non-zero unless Trino answers `select current_user` with exactly USER.

Keycloak's device-approval page is plain HTML forms, so this drives it with
urllib only: no browser and no direct-access grant (which the realm keeps off).
"""
import base64
import http.cookiejar
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

ISSUER = os.environ["ISSUER"].rstrip("/")
TRINO = os.environ["TRINO_URL"].rstrip("/")
USER = os.environ["USER"]
PASSWORD = os.environ["PASSWORD"]
CLIENT_SECRET = open(os.environ["CLIENT_SECRET_FILE"]).read().strip()

FORM = re.compile(r"<form[^>]*>.*?</form>", re.S)
INPUT = re.compile(r'name="([^"]+)" value="([^"]*)"')
ACTION = re.compile(r'action="([^"]+)"')

jar = http.cookiejar.CookieJar()
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))


def get(url):
    with opener.open(urllib.request.Request(url)) as r:
        return r.geturl(), r.read().decode("utf-8", "replace")


def post(url, data):
    body = urllib.parse.urlencode(data).encode()
    with opener.open(urllib.request.Request(url, data=body, method="POST")) as r:
        return r.geturl(), r.read().decode("utf-8", "replace")


def form(resource_url, html):
    """(absolute action URL, {input name: value}) of the only form on the page."""
    match = FORM.search(html)
    if not match:
        sys.exit(f"no form on {resource_url}: {html[:200]}")
    origin = "https://" + urllib.parse.urlsplit(resource_url).netloc
    action = ACTION.search(match.group(0)).group(1).replace("&amp;", "&")
    return (origin + action if action.startswith("/") else action), dict(INPUT.findall(match.group(0)))


def token_endpoint(data):
    """POST the token endpoint, returning the JSON body for both 2xx and 4xx."""
    req = urllib.request.Request(
        f"{ISSUER}/protocol/openid-connect/token", data=urllib.parse.urlencode(data).encode(), method="POST"
    )
    try:
        with opener.open(req) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        return json.loads(e.read().decode())


# 1. Device authorization request for client `trino`.
req = urllib.request.Request(
    f"{ISSUER}/protocol/openid-connect/auth/device",
    data=urllib.parse.urlencode({"client_id": "trino", "client_secret": CLIENT_SECRET, "scope": "openid"}).encode(),
    method="POST",
)
try:
    with opener.open(req) as r:
        device = json.load(r)
except urllib.error.HTTPError as e:
    sys.exit(f"device authorization failed: {e.code} {e.read().decode()[:200]}")

# 2. Approve it as the user: login form, then the consent form.
url, html = get(device["verification_uri_complete"])
action, inputs = form(url, html)
inputs.update({"username": USER, "password": PASSWORD, "credentialId": ""})
url, html = post(action, inputs)
action, inputs = form(url, html)
inputs["accept"] = "Yes"
post(action, inputs)

# 3. Exchange the device code for the user's own access token.
token = None
for _ in range(20):
    token = token_endpoint({"client_id": "trino", "client_secret": CLIENT_SECRET, "scope": "openid",
                            "device_code": device["device_code"],
                            "grant_type": "urn:ietf:params:oauth:grant-type:device_code"})
    if "access_token" in token:
        break
    if token.get("error") not in ("authorization_pending", "slow_down"):
        sys.exit(f"token endpoint refused: {token}")
    time.sleep(5 if token.get("error") == "slow_down" else 2)
if not token or "access_token" not in token:
    sys.exit("device authorization was never approved")

claims = json.loads(base64.urlsafe_b64decode(token["access_token"].split(".")[1] + "=="))
print("  token: aud=%s azp=%s preferred_username=%s"
      % (claims.get("aud"), claims.get("azp"), claims.get("preferred_username")))

# 4. Use that token at Trino and follow the statement to completion. The poll
#    requests deliberately carry no credentials: the nextUri token is the
#    capability, which is why Nova's existing poller keeps working.
hdr = {"Authorization": "Bearer " + token["access_token"], "Content-Type": "text/plain"}
with opener.open(urllib.request.Request(TRINO + "/v1/statement", data=b"select current_user as who",
                                        headers=hdr, method="POST")) as r:
    body = json.load(r)
if not body.get("id"):
    sys.exit(f"Trino refused the token: {json.dumps(body)[:200]}")
print("  query id: %s" % body["id"])
rows = []
while True:
    rows.extend(body.get("data") or [])
    if not body.get("nextUri"):
        break
    with opener.open(urllib.request.Request(body["nextUri"])) as r:
        body = json.load(r)
print("  rows: %s" % rows)
if rows != [[USER]]:
    sys.exit(f"Trino did not authenticate the token as {USER!r}: {rows}")
