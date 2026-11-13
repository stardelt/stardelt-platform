"""The Kafka broker and entity operator declare the Pod Security `restricted` fields (platform#1096)."""

import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]

POD = {
    "fsGroup": 0,
    "runAsNonRoot": True,
    "seccompProfile": {"type": "RuntimeDefault"},
}
CONTAINER = {
    "allowPrivilegeEscalation": False,
    "capabilities": {"drop": ["ALL"]},
    "seccompProfile": {"type": "RuntimeDefault"},
}


class KafkaPodSecurityTest(unittest.TestCase):
    def setUp(self):
        with open(ROOT / "manifests" / "kafka.yaml", encoding="utf-8") as handle:
            docs = [d for d in yaml.safe_load_all(handle) if d]
        self.pool = next(d for d in docs if d["kind"] == "KafkaNodePool")
        self.kafka = next(d for d in docs if d["kind"] == "Kafka")

    def test_the_node_pool_template_carries_the_broker_fields(self):
        # With node pools enabled the broker pod comes from KafkaNodePool.spec.template;
        # Kafka.spec.kafka.template would be ignored.
        template = self.pool["spec"]["template"]
        self.assertEqual(template["pod"]["securityContext"], POD)
        self.assertEqual(template["kafkaContainer"]["securityContext"], CONTAINER)

    def test_the_entity_operator_template_carries_both_containers(self):
        template = self.kafka["spec"]["entityOperator"]["template"]
        self.assertEqual(
            template["pod"]["securityContext"],
            {"runAsNonRoot": True, "seccompProfile": {"type": "RuntimeDefault"}},
        )
        for name in ("topicOperatorContainer", "userOperatorContainer"):
            self.assertEqual(
                template[name]["securityContext"],
                CONTAINER,
                f"{name} would keep the restricted violation",
            )


if __name__ == "__main__":
    unittest.main()
