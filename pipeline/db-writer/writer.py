"""
db-writer: Subscribes to Amazon MQ /topic/hr.events via STOMP+SSL and writes
each HR event to OpenSearch, Aurora PostgreSQL, and Amazon Neptune.

Delivery guarantee: `client-individual` ACK mode (at-least-once).
Each message is ACKed individually only after all three writes succeed.
All writes are idempotent upserts keyed on `employee_id` (and `event_id`
for performance_review rows).

AWS credentials come from Pod Identity bound to the `db-writer` ServiceAccount:
  - OpenSearch: requests-aws4auth SigV4
  - Neptune:    SigV4 headers injected into the WebSocket upgrade request
  - Aurora:     AURORA_PASSWORD env var (no IAM auth needed)

Configuration is injected via the `db-endpoints` ConfigMap and the
`aurora-credentials` / `mq-credentials` Secrets in the `db-writer` namespace.
"""

import json
import logging
import os
import ssl
import time
from typing import Any
from urllib.parse import urlparse, urlunparse

import boto3
import psycopg2
import psycopg2.extras
import stomp
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest
from gremlin_python.driver import serializer
from gremlin_python.driver.driver_remote_connection import DriverRemoteConnection
from gremlin_python.process.anonymous_traversal import traversal
from gremlin_python.process.graph_traversal import __
from gremlin_python.process.traversal import Cardinality
from opensearchpy import OpenSearch, RequestsHttpConnection
from requests_aws4auth import AWS4Auth

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s — %(message)s",
)
logger = logging.getLogger("db-writer")

# ── Configuration ─────────────────────────────────────────────────────────────
MQ_STOMP_URL = os.environ["MQ_STOMP_URL"]
MQ_DESTINATION = os.environ.get("MQ_DESTINATION", "/topic/hr.events")
MQ_USERNAME = os.environ["MQ_USERNAME"]
MQ_PASSWORD = os.environ["MQ_PASSWORD"]

OPENSEARCH_ENDPOINT = os.environ["OPENSEARCH_ENDPOINT"]  # https://host
NEPTUNE_ENDPOINT = os.environ["NEPTUNE_ENDPOINT"]         # wss://host:8182/gremlin
AURORA_ENDPOINT = os.environ["AURORA_ENDPOINT"]
AURORA_PORT = int(os.environ.get("AURORA_PORT", "5432"))
AURORA_DB_NAME = os.environ["AURORA_DB_NAME"]
AURORA_USERNAME = os.environ["AURORA_USERNAME"]
AURORA_PASSWORD = os.environ["AURORA_PASSWORD"]

AWS_REGION = os.environ.get("AWS_REGION", "eu-west-2")
OS_INDEX = "hr-employees"


# ── STOMP host parsing ────────────────────────────────────────────────────────

def _parse_stomp_hosts(failover_url: str) -> list[tuple[str, int]]:
    """
    Parse ``failover:(stomp+ssl://h1:61614,...)?opts``
    into ``[("h1", 61614), ...]``.
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


# ── OpenSearch ────────────────────────────────────────────────────────────────

def _build_opensearch_client() -> OpenSearch:
    session = boto3.Session(region_name=AWS_REGION)
    creds = session.get_credentials().get_frozen_credentials()
    auth = AWS4Auth(
        creds.access_key,
        creds.secret_key,
        AWS_REGION,
        "es",
        session_token=creds.token,
    )
    parsed = urlparse(OPENSEARCH_ENDPOINT)
    return OpenSearch(
        hosts=[{"host": parsed.hostname, "port": parsed.port or 443}],
        http_auth=auth,
        use_ssl=True,
        verify_certs=True,
        connection_class=RequestsHttpConnection,
    )


def _ensure_os_index(client: OpenSearch) -> None:
    if client.indices.exists(index=OS_INDEX):
        return
    client.indices.create(
        index=OS_INDEX,
        body={
            "mappings": {
                "properties": {
                    "employee_id":       {"type": "keyword"},
                    "event_type":        {"type": "keyword"},
                    "full_name":         {"type": "text", "fields": {"raw": {"type": "keyword"}}},
                    "email":             {"type": "keyword"},
                    "department":        {"type": "keyword"},
                    "job_title":         {"type": "text"},
                    "manager_id":        {"type": "keyword"},
                    "location":          {"type": "keyword"},
                    "salary":            {"type": "float"},
                    "currency":          {"type": "keyword"},
                    "skills":            {"type": "keyword"},
                    "hire_date":         {"type": "date"},
                    "performance_score": {"type": "float"},
                    "timestamp":         {"type": "date"},
                }
            }
        },
    )
    logger.info("Created OpenSearch index: %s", OS_INDEX)


def write_to_opensearch(client: OpenSearch, event: dict[str, Any]) -> None:
    """Upsert the employee document — keyed on employee_id."""
    client.index(
        index=OS_INDEX,
        id=event["employee_id"],
        body=event,
    )


# ── Aurora PostgreSQL ─────────────────────────────────────────────────────────

def _get_aurora_conn() -> psycopg2.extensions.connection:
    return psycopg2.connect(
        host=AURORA_ENDPOINT,
        port=AURORA_PORT,
        dbname=AURORA_DB_NAME,
        user=AURORA_USERNAME,
        password=AURORA_PASSWORD,
        connect_timeout=15,
    )


def _ensure_aurora_schema(conn: psycopg2.extensions.connection) -> None:
    with conn.cursor() as cur:
        cur.execute("""
            CREATE TABLE IF NOT EXISTS employees (
                employee_id   TEXT        PRIMARY KEY,
                full_name     TEXT,
                email         TEXT,
                department    TEXT,
                job_title     TEXT,
                manager_id    TEXT,
                location      TEXT,
                salary        NUMERIC,
                currency      TEXT,
                skills        TEXT[],
                hire_date     DATE,
                updated_at    TIMESTAMPTZ DEFAULT NOW()
            )
        """)
        cur.execute("""
            CREATE TABLE IF NOT EXISTS performance_reviews (
                event_id          TEXT    PRIMARY KEY,
                employee_id       TEXT    NOT NULL,
                performance_score NUMERIC,
                reviewed_at       TIMESTAMPTZ
            )
        """)
    conn.commit()
    logger.info("Aurora schema ready")


def write_to_aurora(conn: psycopg2.extensions.connection, event: dict[str, Any]) -> None:
    """Upsert employee row; also upsert performance_review row when applicable."""
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO employees
                (employee_id, full_name, email, department, job_title,
                 manager_id, location, salary, currency, skills, hire_date)
            VALUES
                (%(employee_id)s, %(full_name)s, %(email)s, %(department)s,
                 %(job_title)s, %(manager_id)s, %(location)s, %(salary)s,
                 %(currency)s, %(skills)s, %(hire_date)s)
            ON CONFLICT (employee_id) DO UPDATE SET
                full_name  = EXCLUDED.full_name,
                email      = EXCLUDED.email,
                department = EXCLUDED.department,
                job_title  = EXCLUDED.job_title,
                manager_id = EXCLUDED.manager_id,
                location   = EXCLUDED.location,
                salary     = EXCLUDED.salary,
                currency   = EXCLUDED.currency,
                skills     = EXCLUDED.skills,
                hire_date  = EXCLUDED.hire_date,
                updated_at = NOW()
            """,
            {**event, "skills": event.get("skills") or []},
        )

        if event.get("event_type") == "performance_review" and event.get("performance_score") is not None:
            cur.execute(
                """
                INSERT INTO performance_reviews
                    (event_id, employee_id, performance_score, reviewed_at)
                VALUES
                    (%(event_id)s, %(employee_id)s, %(performance_score)s, %(timestamp)s)
                ON CONFLICT (event_id) DO UPDATE SET
                    performance_score = EXCLUDED.performance_score,
                    reviewed_at       = EXCLUDED.reviewed_at
                """,
                event,
            )
    conn.commit()


# ── Neptune (Gremlin) ─────────────────────────────────────────────────────────

def _get_neptune_headers() -> dict[str, str]:
    """
    Sign the Neptune WebSocket endpoint with SigV4 and return auth headers
    to be passed in the WebSocket upgrade request.
    """
    session = boto3.Session(region_name=AWS_REGION)
    creds = session.get_credentials().get_frozen_credentials()

    https_url = NEPTUNE_ENDPOINT.replace("wss://", "https://")
    parsed = urlparse(https_url)

    request = AWSRequest(method="GET", url=https_url)
    request.headers["host"] = parsed.hostname
    SigV4Auth(creds, "neptune-db", AWS_REGION).add_auth(request)

    headers = {
        "Authorization": request.headers["Authorization"],
        "X-Amz-Date": request.headers["X-Amz-Date"],
        "host": parsed.hostname,
    }
    # Include session token when running with temporary credentials (Pod Identity)
    if "X-Amz-Security-Token" in request.headers:
        headers["X-Amz-Security-Token"] = request.headers["X-Amz-Security-Token"]
    return headers


def _build_neptune_connection() -> DriverRemoteConnection:
    headers = _get_neptune_headers()
    return DriverRemoteConnection(
        NEPTUNE_ENDPOINT,
        "g",
        message_serializer=serializer.GraphSONSerializersV2d0(),
        headers=headers,
    )


def write_to_neptune(event: dict[str, Any]) -> None:
    """
    Upsert an Employee vertex, a REPORTS_TO edge to the manager, and a
    HAS_SKILL edge for each skill listed in the event.

    A new Neptune connection is opened per event so that each write gets a
    freshly signed WebSocket URL (SigV4 tokens expire in ~15 min).
    """
    emp_id = event["employee_id"]
    g_conn = _build_neptune_connection()
    try:
        g = traversal().withRemote(g_conn)

        # ── Upsert Employee vertex ────────────────────────────────────────────
        emp_v = (
            g.V()
            .has("Employee", "employee_id", emp_id)
            .fold()
            .coalesce(
                __.unfold(),
                __.addV("Employee").property("employee_id", emp_id),
            )
            .property(Cardinality.single, "full_name", event.get("full_name", ""))
            .property(Cardinality.single, "department", event.get("department", ""))
            .property(Cardinality.single, "job_title", event.get("job_title", ""))
            .property(Cardinality.single, "location", event.get("location", ""))
            .property(Cardinality.single, "email", event.get("email", ""))
            .next()
        )

        # ── Upsert REPORTS_TO edge ────────────────────────────────────────────
        manager_id = event.get("manager_id")
        if manager_id:
            mgr_v = (
                g.V()
                .has("Employee", "employee_id", manager_id)
                .fold()
                .coalesce(
                    __.unfold(),
                    __.addV("Employee").property("employee_id", manager_id),
                )
                .next()
            )
            # Add edge only if it does not already exist
            (
                g.V(emp_v.id)
                .outE("REPORTS_TO")
                .where(__.inV().hasId(mgr_v.id))
                .fold()
                .coalesce(
                    __.unfold(),
                    __.addE("REPORTS_TO").from_(__.V(emp_v.id)).to(__.V(mgr_v.id)),
                )
                .iterate()
            )

        # ── Upsert HAS_SKILL edges ────────────────────────────────────────────
        for skill in event.get("skills") or []:
            skill_v = (
                g.V()
                .has("Skill", "name", skill)
                .fold()
                .coalesce(
                    __.unfold(),
                    __.addV("Skill").property("name", skill),
                )
                .next()
            )
            (
                g.V(emp_v.id)
                .outE("HAS_SKILL")
                .where(__.inV().hasId(skill_v.id))
                .fold()
                .coalesce(
                    __.unfold(),
                    __.addE("HAS_SKILL").from_(__.V(emp_v.id)).to(__.V(skill_v.id)),
                )
                .iterate()
            )

    finally:
        g_conn.close()


# ── STOMP listener ────────────────────────────────────────────────────────────

class HREventListener(stomp.ConnectionListener):
    """
    Processes incoming STOMP frames from `/topic/hr.events`.
    Each message is written to all three stores before being ACKed.
    Failed messages are NACKed so ActiveMQ can redeliver them.
    """

    def __init__(
        self,
        stomp_conn: stomp.Connection,
        os_client: OpenSearch,
        aurora_conn: psycopg2.extensions.connection,
    ) -> None:
        self._conn = stomp_conn
        self._os = os_client
        self._aurora = aurora_conn

    def on_error(self, frame: stomp.utils.Frame) -> None:
        logger.error("STOMP error: %s", frame.body)

    def on_disconnected(self) -> None:
        logger.warning("STOMP disconnected — waiting for reconnect")

    def on_message(self, frame: stomp.utils.Frame) -> None:
        msg_id = frame.headers.get("message-id", "unknown")
        subscription = frame.headers.get("subscription", "1")
        try:
            event: dict[str, Any] = json.loads(frame.body)
            emp_id = event.get("employee_id", "?")
            event_type = event.get("event_type", "?")
            logger.info(
                "Processing %s event for employee %s (msg %s)",
                event_type,
                emp_id,
                msg_id,
            )

            write_to_opensearch(self._os, event)
            write_to_aurora(self._aurora, event)
            write_to_neptune(event)

            self._conn.ack(msg_id, subscription)
            logger.info("ACKed message %s", msg_id)

        except Exception as exc:
            logger.exception("Failed to process message %s: %s", msg_id, exc)
            try:
                self._conn.nack(msg_id, subscription)
            except Exception:
                pass


# ── Main ──────────────────────────────────────────────────────────────────────

def main() -> None:
    logger.info("db-writer starting up")

    # ── OpenSearch ─────────────────────────────────────────────────────────────
    os_client = _build_opensearch_client()
    _ensure_os_index(os_client)

    # ── Aurora ─────────────────────────────────────────────────────────────────
    aurora_conn = _get_aurora_conn()
    _ensure_aurora_schema(aurora_conn)

    # ── STOMP connection ────────────────────────────────────────────────────────
    stomp_hosts = _parse_stomp_hosts(MQ_STOMP_URL)
    ssl_ctx = ssl.create_default_context()
    ssl_ctx.check_hostname = False
    ssl_ctx.verify_mode = ssl.CERT_NONE

    stomp_conn = stomp.Connection(
        host_and_ports=stomp_hosts,
        use_ssl=True,
        ssl_context=ssl_ctx,
        reconnect_attempts_max=10,
    )
    listener = HREventListener(stomp_conn, os_client, aurora_conn)
    stomp_conn.set_listener("", listener)
    stomp_conn.connect(MQ_USERNAME, MQ_PASSWORD, wait=True)

    stomp_conn.subscribe(
        destination=MQ_DESTINATION,
        id=1,
        ack="client-individual",
    )
    logger.info("Subscribed to %s with ack=client-individual", MQ_DESTINATION)

    # Keep main thread alive while the STOMP listener thread processes messages
    try:
        while True:
            time.sleep(5)
            if not stomp_conn.is_connected():
                logger.warning("STOMP connection lost — attempting reconnect")
                stomp_conn.connect(MQ_USERNAME, MQ_PASSWORD, wait=True)
                stomp_conn.subscribe(
                    destination=MQ_DESTINATION,
                    id=1,
                    ack="client-individual",
                )
    except KeyboardInterrupt:
        logger.info("Shutdown requested")
    finally:
        stomp_conn.disconnect()
        aurora_conn.close()
        logger.info("db-writer shut down")


if __name__ == "__main__":
    main()
