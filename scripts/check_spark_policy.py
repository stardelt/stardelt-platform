#!/usr/bin/env python3
"""Check one SparkCluster's ingress policy (operator#471) — the rule that keeps Spark Connect closed.

    kubectl -n stardelt get networkpolicy spc-trial-ingress -o json | \
        python3 scripts/check_spark_policy.py --name trial --group mobility-analytics

Reads the NetworkPolicy JSON on stdin. Prints `ok` and exits 0, or one problem per line on
stderr and exits 1. Standard library only, so CI's unittest run covers the rules.
"""

import argparse
import json
import sys

PORT = 15002
CONNECT_LABEL = "sparkoperator.k8s.io/connect-name"


def _labels(peer):
    return ((peer or {}).get("podSelector") or {}).get("matchLabels") or {}


def check(policy, name, group=None, user=None):
    """The problems of one policy; an empty list means it admits the owner, Nova and Airflow only."""
    problems = []
    expected = f"spc-{name}"
    if (policy.get("metadata") or {}).get("name") != f"{expected}-ingress":
        problems.append(f"the policy is not named {expected}-ingress")
    spec = policy.get("spec") or {}
    selector = (spec.get("podSelector") or {}).get("matchLabels") or {}
    if selector.get(CONNECT_LABEL) != expected:
        problems.append(f"podSelector does not select {CONNECT_LABEL}={expected} (got {selector!r})")
    if "Ingress" not in (spec.get("policyTypes") or []):
        problems.append("policyTypes does not include Ingress")
    rules = spec.get("ingress") or []
    if len(rules) != 1:
        problems.append(f"expected one ingress rule, found {len(rules)}")
        return problems
    rule = rules[0]
    ports = [p.get("port") for p in rule.get("ports") or []]
    if PORT not in ports:
        problems.append(f"the rule does not open TCP {PORT} (got {ports!r})")
    peers = rule.get("from") or []
    if group:
        if {"stardelt.io/group.%s" % group: "true"} not in [_labels(peer) for peer in peers]:
            problems.append(f"no peer admits group {group} (stardelt.io/group.{group}=true)")
    elif user:
        if {"stardelt.io/user": user} not in [_labels(peer) for peer in peers]:
            problems.append(f"no peer admits user {user} (stardelt.io/user={user})")
    else:
        problems.append("the SparkCluster names no owner")
    if {"app.kubernetes.io/name": "nova"} not in [_labels(peer) for peer in peers]:
        problems.append("no peer admits Nova (app.kubernetes.io/name=nova)")
    if not any(_labels(peer).get("release") == "airflow" and _labels(peer).get("component") == "worker" for peer in peers):
        problems.append("no peer admits the Airflow worker (release=airflow, component=worker)")
    return problems


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--name", required=True, help="the SparkCluster's name")
    parser.add_argument("--group", help="spec.owner.group")
    parser.add_argument("--user", help="spec.owner.user")
    args = parser.parse_args(argv)
    try:
        policy = json.load(sys.stdin)
    except ValueError as err:
        print(f"the policy is not JSON: {err}", file=sys.stderr)
        return 1
    problems = check(policy, args.name, group=args.group, user=args.user)
    if problems:
        for problem in problems:
            print(problem, file=sys.stderr)
        return 1
    print("ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
