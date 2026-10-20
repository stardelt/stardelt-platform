"""The one process a notebook task pod runs: fetch, run, upload, cancel on stop.

A scheduled notebook is user code, so its pod holds no storage credential (spike #272: a
bucket-scoped key can read every bucket through CopyObject). The DAG in the Airflow worker,
which does hold the object-store connection, signs two URLs and hands them to this pod:

    NOTEBOOK_GET_URL         pre-signed GET of the pinned object version (the notebook to run)
    NOTEBOOK_PUT_URL         pre-signed PUT of the executed copy (`_runs/...`)

Everything else comes from the contract the pipeline's `sql` tasks already use:

    NOTEBOOK_PARAMS          JSON object of parameter values (strings only)
    NOTEBOOK_RUN_DATE        YYYY-MM-DD of the run, passed as `run_date`
    NOTEBOOK_RUN_ID          the run's id, passed as `run_id`
    TRINO_URL                the query engine (also to cancel a statement on stop)
    REQUESTS_CA_BUNDLE       the internal CA that signs the engine's certificate
    PIPELINE_*               the pipeline principal's credentials (``stardelt._token()``)
    STARDELT_QUERY_IDS       file of statement ids to cancel on stop (default /tmp/stardelt-query-ids)
    STARDELT_PAPERMILL       the papermill executable (default ``papermill``; tests only)

``python -m stardelt.notebook_run`` downloads the notebook to /tmp/in.ipynb, runs papermill in a
process group of its own, and uploads /tmp/out.ipynb — after a failure too, because papermill
records the failing cell there. It exits with papermill's code, 143 when a stop (SIGTERM)
interrupted the run, and 2 for a contract error.

A stop deletes the pod, which kills the kernel but NOT the statement Trino is running (it keeps
going for about five minutes, spike #267). Before exiting, the wrapper cancels every statement id
the helper recorded (``DELETE /v1/query/<id>`` as the principal's token).

Nothing secret is logged: stages and byte counts only — never a URL, a token, a parameter value or
notebook text. The executed notebook is redacted of this pod's own tokens before the upload.

SPDX-License-Identifier: MIT
"""

import json
import logging
import os
import signal
import subprocess
import sys
import time

import requests

import stardelt

log = logging.getLogger("stardelt.notebook_run")

PATH_IN = "/tmp/in.ipynb"
PATH_OUT = "/tmp/out.ipynb"
DEFAULT_QUERY_IDS = "/tmp/stardelt-query-ids"

DOWNLOAD_LIMIT = 10 * 1024 * 1024
UPLOAD_LIMIT = 20 * 1024 * 1024
UPLOAD_TIMEOUT_SECONDS = 20
STOP_GRACE_SECONDS = 10
REDACTED = "[redacted]"

# Values shorter than this are not treated as a token to redact: a one-letter or empty value is
# not a credential, and replacing it would mangle the notebook without hiding anything.
MIN_REDACT_BYTES = 8

# The pod's own secrets. They must never travel from a cell's output into the stored notebook.
SECRET_VARIABLES = ("TRINO_TOKEN", "PIPELINE_CLIENT_SECRET")


class ContractError(Exception):
    """The pod's environment does not hold a usable notebook-task contract."""


def _required(name):
    """The value of a required variable, or a one-line ``ContractError`` naming it."""
    value = os.environ.get(name, "").strip()
    if not value:
        raise ContractError(f"{name} is not set — the DAG must give this pod its notebook contract.")
    return value


def download(url, dest, limit=DOWNLOAD_LIMIT):
    """Stream the notebook behind a pre-signed GET into ``dest``; return its size in bytes.

    The URL is a credential and is never put into a message or a log line: a failure names the
    HTTP status (or the fact that the size limit was hit), nothing else.
    """
    if not url:
        raise ContractError("NOTEBOOK_GET_URL is not set — the DAG must sign the notebook for this pod.")
    try:
        with requests.get(url, stream=True, timeout=30) as response:
            if response.status_code != 200:
                raise ContractError(f"the notebook could not be fetched (HTTP {response.status_code})")
            declared = response.headers.get("Content-Length", "")
            if declared.isdigit() and int(declared) > limit:
                raise ContractError(f"the notebook is bigger than the {limit}-byte limit")
            size = 0
            with open(dest, "wb") as out:
                for chunk in response.iter_content(64 * 1024):
                    size += len(chunk)
                    if size > limit:
                        raise ContractError(f"the notebook is bigger than the {limit}-byte limit")
                    out.write(chunk)
    except requests.RequestException as exc:
        raise ContractError(f"the notebook could not be fetched ({type(exc).__name__})") from None
    except ContractError:
        try:
            os.unlink(dest)
        except OSError:
            pass
        raise
    return size


def parameters():
    """The merged parameter dict: ``run_date``, ``run_id`` first, then ``NOTEBOOK_PARAMS``.

    Run values are reserved: a saved parameter of the same name cannot date the run differently
    from the run the scheduler started. Values stay strings (papermill ``-r`` passes them raw, so
    ``0123`` reaches the notebook as text).
    """
    merged = {"run_date": _required("NOTEBOOK_RUN_DATE"), "run_id": _required("NOTEBOOK_RUN_ID")}
    raw = os.environ.get("NOTEBOOK_PARAMS", "").strip() or "{}"
    try:
        given = json.loads(raw)
    except ValueError:
        raise ContractError("NOTEBOOK_PARAMS is not valid JSON") from None
    if not isinstance(given, dict):
        raise ContractError("NOTEBOOK_PARAMS must be a JSON object of string values")
    for name, value in given.items():
        if not isinstance(value, str):
            raise ContractError(f"NOTEBOOK_PARAMS value for {name!r} is not a string")
    for name, value in given.items():
        merged.setdefault(name, value)
    return merged


def build_command(params):
    """The papermill argument list (no shell): ``-r`` pairs sorted, then the CLI flags."""
    executable = os.environ.get("STARDELT_PAPERMILL", "").strip() or "papermill"
    command = [executable, PATH_IN, PATH_OUT]
    for name in sorted(params):
        command += ["-r", name, str(params[name])]
    command += ["--no-progress-bar", "--log-output", "--kernel", "python3"]
    return command


def _query_ids_path():
    """The file the helper appends statement ids to (``STARDELT_QUERY_IDS`` or the default)."""
    return os.environ.get("STARDELT_QUERY_IDS", "").strip() or DEFAULT_QUERY_IDS


def _recorded_ids(path):
    """The statement ids in ``path``, de-duplicated; a missing file is no ids."""
    try:
        with open(path, encoding="utf-8") as handle:
            lines = handle.read().split()
    except OSError:
        return []
    ids, seen = [], set()
    for line in lines:
        if line in ("", "None") or line in seen:
            continue
        seen.add(line)
        ids.append(line)
    return ids


def cancel_recorded_queries():
    """Cancel every statement this run recorded; return how many the engine accepted.

    ``DELETE /v1/query/<id>`` with the principal's bearer cancels a statement of that principal
    (spike #255); 404 means it already finished, which is not an error. A stop must never fail
    because the engine, the token or the file is missing — it logs and leaves the statements.
    """
    ids = _recorded_ids(_query_ids_path())
    if not ids:
        log.info("stop: no statement was recorded, nothing to cancel")
        return 0
    url = os.environ.get("TRINO_URL", "").strip().rstrip("/")
    if not url:
        log.info("stop: TRINO_URL is not set, %d statement(s) left to finish", len(ids))
        return 0
    try:
        token = stardelt._token()
    except Exception as exc:  # noqa: BLE001 - a stop has to finish even without a token
        log.info(
            "stop: no token to cancel with (%s), %d statement(s) left to finish",
            stardelt._one_line(exc),
            len(ids),
        )
        return 0
    headers = {"Authorization": f"Bearer {token}"}
    cancelled = 0
    for query_id in ids:
        try:
            response = requests.delete(f"{url}/v1/query/{query_id}", headers=headers, timeout=10)
        except requests.RequestException as exc:
            log.info("stop: the engine was not reachable to cancel (%s)", type(exc).__name__)
            continue
        if response.status_code in (200, 204):
            cancelled += 1
        elif response.status_code != 404:
            log.info("stop: the engine answered HTTP %d to one cancel", response.status_code)
    log.info("stop: cancelled %d of %d recorded statement(s)", cancelled, len(ids))
    return cancelled


def _redacted_bytes(path):
    """The notebook's bytes with this pod's own token values replaced by ``[redacted]``."""
    with open(path, "rb") as handle:
        body = handle.read()
    hits = 0
    for name in SECRET_VARIABLES:
        secret = os.environ.get(name, "").strip().encode()
        if len(secret) < MIN_REDACT_BYTES or secret not in body:
            continue
        hits += body.count(secret)
        body = body.replace(secret, REDACTED.encode())
    if hits:
        log.info("upload: redacted %d token occurrence(s) from the executed notebook", hits)
    return body


def upload(path, url, limit=UPLOAD_LIMIT):
    """PUT the executed notebook to a pre-signed URL; return the bytes uploaded."""
    if not url:
        raise ContractError("NOTEBOOK_PUT_URL is not set — the DAG must sign the output key for this pod.")
    body = _redacted_bytes(path)
    if len(body) > limit:
        raise ContractError(f"the executed notebook is bigger than the {limit}-byte limit")
    try:
        response = requests.put(
            url,
            data=body,
            headers={"Content-Type": "application/x-ipynb+json"},
            timeout=UPLOAD_TIMEOUT_SECONDS,
        )
    except requests.RequestException as exc:
        raise ContractError(f"the executed notebook could not be uploaded ({type(exc).__name__})") from None
    if response.status_code not in (200, 201, 204):
        raise ContractError(f"the executed notebook could not be uploaded (HTTP {response.status_code})")
    return len(body)


def _kill_group(child):
    """SIGKILL papermill's whole process group (the kernel is a child of it)."""
    try:
        os.killpg(child.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def _wait(child, stopping):
    """Wait for papermill; after a stop, give it the grace period, then kill the group."""
    grace = None
    while True:
        try:
            return child.wait(timeout=1)
        except subprocess.TimeoutExpired:
            if not stopping():
                continue
            if grace is None:
                grace = time.monotonic() + STOP_GRACE_SECONDS
            elif time.monotonic() >= grace:
                log.info("stop: papermill did not exit within %d s, killing it", STOP_GRACE_SECONDS)
                _kill_group(child)
                return child.wait()


def main():
    """Run one notebook task; return the exit code the pod should carry."""
    logging.basicConfig(stream=sys.stderr, level=logging.INFO, format="%(message)s")
    stopping = False
    child = None

    def on_sigterm(signum, frame):  # noqa: ARG001 - the signal handler signature
        nonlocal stopping
        if stopping:
            return
        stopping = True
        log.info("stop requested: cancelling the recorded statements")
        cancel_recorded_queries()
        if child is not None and child.poll() is None:
            try:
                os.killpg(child.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass

    previous = signal.signal(signal.SIGTERM, on_sigterm)
    try:
        try:
            size = download(_required("NOTEBOOK_GET_URL"), PATH_IN)
            log.info("downloaded the notebook: %d bytes", size)
            if stopping:  # the pod is being deleted; there is no run to start
                log.info("stop requested during the download; not starting the notebook")
                return 143
            params = parameters()
            log.info("running the notebook: %d parameter(s)", len(params))
            environment = dict(os.environ)
            # The helper only records ids when the file is named; the wrapper always needs them,
            # so the child gets the path even when the DAG did not set it.
            environment.setdefault("STARDELT_QUERY_IDS", _query_ids_path())
            child = subprocess.Popen(
                build_command(params), start_new_session=True, env=environment
            )
            rc = _wait(child, lambda: stopping)
        except ContractError as exc:
            log.error("%s", exc)
            return 2

        if stopping:
            rc = 143
        if os.path.exists(PATH_OUT):
            try:
                written = upload(PATH_OUT, os.environ.get("NOTEBOOK_PUT_URL", "").strip())
                log.info("uploaded the executed notebook: %d bytes", written)
            except ContractError as exc:
                log.error("%s", exc)
                if rc == 0:
                    rc = 1
        else:
            log.info("the notebook produced no executed copy to upload")
        return rc
    finally:
        signal.signal(signal.SIGTERM, previous)
        if child is not None and child.poll() is None:
            _kill_group(child)
            child.wait()


if __name__ == "__main__":
    sys.exit(main())
