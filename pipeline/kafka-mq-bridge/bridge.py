"""
kafka-mq-bridge: Consumes from MSK Kafka topic `hr-events` and publishes
each message to Amazon MQ `/topic/hr.events` via STOMP+SSL.

MSK auth:  IAM SASL via Pod Identity on the `emr-job-runner` ServiceAccount.
MQ auth:   username/password from env vars MQ_USERNAME / MQ_PASSWORD.
Batching:  messages are committed to Kafka and sent inside a STOMP transaction
           in groups of BATCH_SIZE (default 10).

Configuration is injected via the `bridge-config` ConfigMap and the
`bridge-mq-credentials` Secret in the `emr-jobs` namespace.
"""

import logging
import os
import ssl
import time

import stomp
from aws_msk_iam_sasl_signer import MSKAuthTokenProvider
from confluent_kafka import Consumer, KafkaError, KafkaException
from confluent_kafka.admin import AdminClient, NewTopic

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s — %(message)s",
)
logger = logging.getLogger("kafka-mq-bridge")

# ── Configuration (injected via ConfigMap + Secret) ───────────────────────────
KAFKA_BOOTSTRAP_SERVERS = os.environ["KAFKA_BOOTSTRAP_SERVERS"]
KAFKA_TOPIC = os.environ.get("KAFKA_TOPIC", "hr-events")
KAFKA_GROUP_ID = os.environ.get("KAFKA_GROUP_ID", "kafka-mq-bridge")
MQ_STOMP_URL = os.environ["MQ_STOMP_URL"]
MQ_DESTINATION = os.environ.get("MQ_DESTINATION", "/topic/hr.events")
MQ_USERNAME = os.environ["MQ_USERNAME"]
MQ_PASSWORD = os.environ["MQ_PASSWORD"]
AWS_REGION = os.environ.get("AWS_REGION", "eu-west-2")
BATCH_SIZE = int(os.environ.get("BATCH_SIZE", "10"))


# ── MSK IAM SASL OAuth callback ───────────────────────────────────────────────

def _msk_oauth_callback(config: dict) -> tuple[str, float]:
    """
    Called by confluent_kafka to refresh the MSK IAM token.
    Returns (token, expiry_seconds_since_epoch).
    """
    token, expiry_ms = MSKAuthTokenProvider.generate_auth_token(AWS_REGION)
    return token, expiry_ms / 1000  # confluent_kafka expects seconds


# ── Kafka helpers ─────────────────────────────────────────────────────────────

def _kafka_config() -> dict:
    return {
        "bootstrap.servers": KAFKA_BOOTSTRAP_SERVERS,
        "security.protocol": "SASL_SSL",
        "sasl.mechanism": "OAUTHBEARER",
        "oauth_cb": _msk_oauth_callback,
    }


def ensure_topic(topic: str) -> None:
    """Create `topic` if it does not already exist on the MSK cluster."""
    admin = AdminClient(_kafka_config())
    metadata = admin.list_topics(timeout=15)
    if topic in metadata.topics:
        logger.info("Kafka topic already exists: %s", topic)
        return

    logger.info("Creating Kafka topic: %s", topic)
    futures = admin.create_topics(
        [NewTopic(topic, num_partitions=3, replication_factor=2)]
    )
    for t, fut in futures.items():
        try:
            fut.result()
            logger.info("Topic created: %s", t)
        except Exception as exc:
            # Topic may have been created by another instance racing us
            logger.warning("Could not create topic %s: %s", t, exc)


def build_consumer() -> Consumer:
    cfg = _kafka_config()
    cfg.update(
        {
            "group.id": KAFKA_GROUP_ID,
            "auto.offset.reset": "earliest",
            "enable.auto.commit": False,
        }
    )
    return Consumer(cfg)


# ── STOMP helpers ─────────────────────────────────────────────────────────────

def _parse_stomp_hosts(failover_url: str) -> list[tuple[str, int]]:
    """
    Parse ``failover:(stomp+ssl://h1:61614,stomp+ssl://h2:61614)?...``
    into ``[("h1", 61614), ("h2", 61614)]``.
    """
    inner = failover_url.split("(", 1)[1].split(")", 1)[0]
    hosts: list[tuple[str, int]] = []
    for entry in inner.split(","):
        entry = (
            entry.strip()
            .replace("stomp+ssl://", "")
            .replace("stomp://", "")
        )
        host, port_str = entry.rsplit(":", 1)
        hosts.append((host, int(port_str)))
    return hosts


class StompPublisher:
    """
    Wraps ``stomp.Connection`` with STOMP+SSL and transactional batch publishing.
    Reconnects automatically on failure.
    """

    def __init__(
        self,
        hosts: list[tuple[str, int]],
        username: str,
        password: str,
    ) -> None:
        self._hosts = hosts
        self._username = username
        self._password = password
        self._connect()

    def _connect(self) -> None:
        ssl_ctx = ssl.create_default_context()
        # Amazon MQ uses a private CA; skip hostname verification inside VPC
        ssl_ctx.check_hostname = False
        ssl_ctx.verify_mode = ssl.CERT_NONE

        self._conn = stomp.Connection(
            host_and_ports=self._hosts,
            use_ssl=True,
            ssl_context=ssl_ctx,
            reconnect_attempts_max=10,
        )
        self._conn.connect(self._username, self._password, wait=True)
        logger.info("Connected to Amazon MQ STOMP: %s", self._hosts)

    def publish_batch(self, messages: list[str], destination: str) -> None:
        """
        Send *messages* inside a single STOMP transaction (persistent delivery).
        Aborts the transaction and re-raises on any error.
        """
        tx_id = f"hr-batch-{int(time.monotonic() * 1000)}"
        self._conn.begin(transaction=tx_id)
        try:
            for body in messages:
                self._conn.send(
                    destination=destination,
                    body=body,
                    headers={
                        "content-type": "application/json",
                        "persistent": "true",
                    },
                    transaction=tx_id,
                )
            self._conn.commit(transaction=tx_id)
        except Exception:
            try:
                self._conn.abort(transaction=tx_id)
            except Exception:
                pass
            raise


# ── Main loop ─────────────────────────────────────────────────────────────────

def run() -> None:
    logger.info("kafka-mq-bridge starting")
    logger.info("  Kafka topic     : %s", KAFKA_TOPIC)
    logger.info("  MQ destination  : %s", MQ_DESTINATION)
    logger.info("  Batch size      : %d", BATCH_SIZE)

    ensure_topic(KAFKA_TOPIC)

    stomp_hosts = _parse_stomp_hosts(MQ_STOMP_URL)
    publisher = StompPublisher(stomp_hosts, MQ_USERNAME, MQ_PASSWORD)

    consumer = build_consumer()
    consumer.subscribe([KAFKA_TOPIC])
    logger.info("Subscribed to Kafka topic: %s", KAFKA_TOPIC)

    batch: list[str] = []
    try:
        while True:
            msg = consumer.poll(timeout=5.0)

            if msg is None:
                # Idle — flush any partial batch so we don't hold offsets
                if batch:
                    publisher.publish_batch(batch, MQ_DESTINATION)
                    consumer.commit(asynchronous=False)
                    logger.info(
                        "Flushed partial batch of %d message(s) to %s",
                        len(batch),
                        MQ_DESTINATION,
                    )
                    batch = []
                continue

            if msg.error():
                if msg.error().code() == KafkaError._PARTITION_EOF:
                    continue
                raise KafkaException(msg.error())

            batch.append(msg.value().decode("utf-8"))

            if len(batch) >= BATCH_SIZE:
                publisher.publish_batch(batch, MQ_DESTINATION)
                consumer.commit(asynchronous=False)
                logger.info(
                    "Published batch of %d message(s) to %s",
                    len(batch),
                    MQ_DESTINATION,
                )
                batch = []

    finally:
        # Flush remaining messages before shutdown
        if batch:
            try:
                publisher.publish_batch(batch, MQ_DESTINATION)
                consumer.commit(asynchronous=False)
                logger.info("Flushed %d remaining message(s) on shutdown", len(batch))
            except Exception as exc:
                logger.error("Failed to flush remaining messages: %s", exc)
        consumer.close()
        logger.info("kafka-mq-bridge shut down")


if __name__ == "__main__":
    run()
