"""Tests for scripts/check_spark_policy.py (operator#471's ingress rule). Standard library only."""

import unittest

from scripts.check_spark_policy import check


def policy(name="trial", owner=("mobility-analytics", None), port=15002):
    group, user = owner
    owner_peer = (
        {"podSelector": {"matchLabels": {"stardelt.io/group.%s" % group: "true"}}} if group
        else {"podSelector": {"matchLabels": {"stardelt.io/user": user}}}
    )
    return {
        "metadata": {"name": "spc-%s-ingress" % name},
        "spec": {
            "podSelector": {"matchLabels": {"sparkoperator.k8s.io/connect-name": "spc-%s" % name}},
            "policyTypes": ["Ingress"],
            "ingress": [{
                "from": [
                    owner_peer,
                    {"podSelector": {"matchLabels": {"app.kubernetes.io/name": "nova"}}},
                    {"podSelector": {"matchLabels": {"release": "airflow", "component": "worker"}}},
                ],
                "ports": [{"port": port, "protocol": "TCP"}],
            }],
        },
    }


class CheckTest(unittest.TestCase):
    def test_a_group_owned_cluster_passes(self):
        self.assertEqual(check(policy(), "trial", group="mobility-analytics"), [])

    def test_a_user_owned_cluster_passes(self):
        self.assertEqual(check(policy(owner=(None, "ada")), "trial", user="ada"), [])

    def test_the_wrong_port_fails(self):
        problems = check(policy(port=15001), "trial", group="mobility-analytics")
        self.assertTrue(any("15002" in problem for problem in problems), problems)

    def test_a_missing_nova_peer_fails(self):
        document = policy()
        document["spec"]["ingress"][0]["from"].pop(1)
        problems = check(document, "trial", group="mobility-analytics")
        self.assertTrue(any("Nova" in problem for problem in problems), problems)

    def test_a_policy_for_another_cluster_fails(self):
        problems = check(policy(), "shared", group="mobility-analytics")
        self.assertTrue(any("spc-shared" in problem for problem in problems), problems)


if __name__ == "__main__":
    unittest.main()
