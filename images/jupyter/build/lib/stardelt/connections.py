"""Named connections to outside systems, for a notebook (decisions D23 and D27).

    import stardelt

    crm = stardelt.connection("crm-db")          # yours, or your group's
    engine = sqlalchemy.create_engine(crm.sqlalchemy_url(driver="psycopg"))

Identity comes from the pod, never from an argument: the signed-in person's token
(``TRINO_TOKEN``, the same one ``stardelt.sql`` uses) signs in to the platform's secret
store. The store, not this package, decides what that person may read: their own
connections and the connections of the groups they belong to. Connections that
administrators manage (``managed``) cannot be read by anybody; the platform uses them on
your behalf (a federated catalog, an ingestion template), so this function says so instead
of returning them.

A value is fetched **when you ask for it** and never kept: ``crm.value("password")`` reads the
store every time, so a rotation is seen on the next call and nothing sits in a variable you
did not create. Printing a connection shows its name, scope, type and the *names* of its
fields, never a value.

SPDX-License-Identifier: MIT
"""

import base64
import json
import os
from urllib.parse import quote

import requests

DEFAULT_ROLE = "platform-users"
DEFAULT_MOUNT = "secret"
TIMEOUT_SECONDS = 15


class ConnectionUnavailable(RuntimeError):
    """The connection cannot be used; the message says why in one line."""


def _claims(token):
    """The claims inside the JWT, without verifying it (the store verifies)."""
    if not token or token.count(".") != 2:
        return {}
    payload = token.split(".")[1]
    payload += "=" * (-len(payload) % 4)
    try:
        return json.loads(base64.urlsafe_b64decode(payload))
    except (ValueError, UnicodeDecodeError):
        return {}


def _name_ok(name):
    return (
        isinstance(name, str)
        and 1 <= len(name) <= 40
        and name[0].islower()
        and name.isascii()
        and name[-1] != "-"
        and all(c.islower() or c.isdigit() or c == "-" for c in name)
    )


def _group_ok(group):
    return (
        isinstance(group, str)
        and 1 <= len(group) <= 64
        and group[0].isalnum()
        and group.isascii()
        and all(c.isalnum() or c in "._-" for c in group)
    )


def _sub_ok(sub):
    return (
        isinstance(sub, str)
        and 1 <= len(sub) <= 128
        and not sub.startswith(".")
        and sub.isascii()
        and all(c.isalnum() or c in "_-.:@" for c in sub)
    )


def _one_line(text):
    lines = str(text).strip().splitlines()
    return lines[0][:200] if lines else ""


class _Store:
    """The few calls to the store a notebook needs. Holds the store token for one call chain."""

    def __init__(self):
        self.url = os.environ.get("STARDELT_SECRET_STORE_URL", "").strip().rstrip("/")
        if not self.url:
            raise ConnectionUnavailable(
                "STARDELT_SECRET_STORE_URL is not set — this server was started before the secret "
                "store was configured; restart it from the hub."
            )
        self.user_token = os.environ.get("TRINO_TOKEN", "").strip()
        if not self.user_token:
            raise ConnectionUnavailable(
                "TRINO_TOKEN is not set — restart this server from the hub so it picks up your sign-in token."
            )
        self.role = os.environ.get("STARDELT_SECRET_STORE_ROLE", DEFAULT_ROLE).strip() or DEFAULT_ROLE
        self.mount = os.environ.get("STARDELT_SECRET_STORE_MOUNT", DEFAULT_MOUNT).strip() or DEFAULT_MOUNT
        self.claims = _claims(self.user_token)
        self._token = None

    def _request(self, method, path, **kwargs):
        try:
            return requests.request(method, f"{self.url}{path}", timeout=TIMEOUT_SECONDS, **kwargs)
        except requests.RequestException as exc:
            raise ConnectionUnavailable(
                f"the secret store is not reachable ({type(exc).__name__})"
            ) from None

    def token(self):
        if self._token is None:
            response = self._request(
                "POST", "/v1/auth/jwt/login", json={"role": self.role, "jwt": self.user_token}
            )
            if response.status_code != 200:
                try:
                    why = _one_line((response.json().get("errors") or [""])[0])
                except ValueError:
                    why = f"HTTP {response.status_code}"
                raise ConnectionUnavailable(
                    f"the secret store refused your sign-in ({why}) — restart this server from the hub "
                    "to get a fresh token."
                )
            self._token = response.json()["auth"]["client_token"]
        return self._token

    def get(self, kind, path):
        """The JSON ``data`` of a store read, ``None`` when the path does not exist or is not yours."""
        response = self._request(
            "GET",
            f"/v1/{self.mount}/{kind}/{path}",
            headers={"X-Vault-Token": self.token()},
        )
        if response.status_code in (403, 404):
            return None
        if response.status_code != 200:
            raise ConnectionUnavailable(f"the secret store answered HTTP {response.status_code}")
        return response.json().get("data") or {}


class Connection:
    """One connection. Settings and field names are known; values are read from the store when asked."""

    def __init__(self, name, scope, group, path, meta):
        self.name = name
        self.scope = scope
        self.group = group
        self._path = path
        custom = meta.get("custom_metadata") or {}
        self.type = custom.get("type", "")
        self.keys = [k for k in custom.get("keys", "").split(",") if k]
        self.settings = {
            k[len("config."):]: v for k, v in custom.items() if k.startswith("config.")
        }

    def __repr__(self):
        where = f"group={self.group}" if self.group else f"scope={self.scope}"
        return f"Connection({self.name!r}, {where}, type={self.type!r}, keys={self.keys})"

    __str__ = __repr__

    def value(self, key):
        """The current value of one secret field, read from the store now."""
        if key not in self.keys:
            raise KeyError(f"connection {self.name!r} has no field {key!r}; its fields are {self.keys}")
        data = _Store().get("data", self._path)  # a fresh sign-in each time: nothing is kept between calls
        if data is None or key not in (data.get("data") or {}):
            raise ConnectionUnavailable(
                f"connection {self.name!r} could not be read any more — it was removed, or you no longer may read it."
            )
        return str(data["data"][key])

    def sqlalchemy_url(self, driver=None):
        """A SQLAlchemy URL for a database connection, with user and password quoted."""
        schemes = {"postgresql": "postgresql", "mysql": "mysql", "sqlserver": "mssql", "oracle": "oracle"}
        if self.type not in schemes:
            raise ConnectionUnavailable(f"sqlalchemy_url() is for database connections, not {self.type!r}")
        scheme = schemes[self.type] + (f"+{driver}" if driver else "")
        host = self.settings["host"]
        port = f":{self.settings['port']}" if self.settings.get("port") else ""
        database = f"/{quote(self.settings['database'], safe='')}" if self.settings.get("database") else ""
        user = quote(self.value("user"), safe="")
        password = quote(self.value("password"), safe="")
        return f"{scheme}://{user}:{password}@{host}{port}{database}"

    def requests_session(self):
        """A ``requests.Session`` that sends the connection's token as a bearer token."""
        if self.type != "rest-api" or "token" not in self.keys:
            raise ConnectionUnavailable(
                "requests_session() needs a rest-api connection with a token field; for client credentials use value()."
            )
        session = requests.Session()
        session.headers["Authorization"] = f"Bearer {self.value('token')}"
        session.base_url = self.settings.get("baseUrl", "")
        return session

    def s3_options(self):
        """Keyword arguments for s3fs, and ``storage_options`` for pandas and PyArrow."""
        if self.type != "s3":
            raise ConnectionUnavailable(f"s3_options() is for s3 connections, not {self.type!r}")
        options = {"key": self.value("accessKeyId"), "secret": self.value("secretAccessKey")}
        client_kwargs = {}
        if self.settings.get("endpoint"):
            client_kwargs["endpoint_url"] = self.settings["endpoint"]
        if self.settings.get("region"):
            client_kwargs["region_name"] = self.settings["region"]
        if client_kwargs:
            options["client_kwargs"] = client_kwargs
        return options


def connection(name, scope=None, group=None):
    """Find the connection ``name`` that you may use.

    Looks at your own connections first, then at the connections of each of your groups. If the
    name exists in more than one of your groups, say which with ``group="analytics"``. ``scope``
    (``"personal"`` or ``"group"``) narrows the search.
    """
    if not _name_ok(name):
        raise ConnectionUnavailable(
            "a connection name is 1 to 40 lower-case letters, digits and dashes, starting with a letter."
        )
    if scope not in (None, "personal", "group"):
        raise ConnectionUnavailable("scope must be 'personal' or 'group' (managed connections are not revealed).")
    store = _Store()
    sub = store.claims.get("sub", "")
    groups = [g for g in (store.claims.get("groups") or []) if _group_ok(g)]
    if group is not None:
        if group not in groups:
            raise ConnectionUnavailable(f"you are not a member of the group {group!r}.")
        groups = [group]

    found = []
    if scope in (None, "personal") and group is None and _sub_ok(sub):
        path = f"connections/user/{sub}/{name}"
        meta = store.get("metadata", path)
        if meta is not None:
            found.append(Connection(name, "personal", None, path, meta))
    if scope in (None, "group"):
        for g in groups:
            path = f"connections/group/{g}/{name}"
            meta = store.get("metadata", path)
            if meta is not None:
                found.append(Connection(name, "group", g, path, meta))
    if not found:
        raise ConnectionUnavailable(
            f"no connection {name!r} that you may read. Check the name on the Connections page. "
            "Connections that administrators manage are used by the platform for you (a catalog, an "
            "ingestion template) and are not revealed to notebooks."
        )
    if len(found) > 1:
        names = ", ".join(c.group or "personal" for c in found)
        raise ConnectionUnavailable(
            f"{name!r} exists in more than one place ({names}); pass group=... or scope=... to choose."
        )
    return found[0]
