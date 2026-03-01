# HR Pipeline — Developer Guide

This guide explains how each component of the HR Seed Data Pipeline works at the code level. It is aimed at application teams who need to understand, extend, or debug the jobs that run on EKS.

**Source files**

| Component | File |
|---|---|
| Spark batch job | `pipeline/spark-jobs/hr_events_producer.py` |
| Kafka → MQ bridge | `pipeline/kafka-mq-bridge/bridge.py` |
| MQ → database writer | `pipeline/db-writer/writer.py` |
| Seed data | `pipeline/seed-data/hr_employees.jsonl` |

---

## Table of Contents

1. [Pipeline Overview](#1-pipeline-overview)
2. [How Jobs Run on EKS](#2-how-jobs-run-on-eks)
3. [Spark Job — hr\_events\_producer.py](#3-spark-job--hr_events_producerpy)
4. [kafka-mq-bridge — bridge.py](#4-kafka-mq-bridge--bridgepy)
5. [db-writer — writer.py](#5-db-writer--writerpy)
6. [Configuration Reference](#6-configuration-reference)
7. [Building and Deploying the Containers](#7-building-and-deploying-the-containers)
8. [Running the Pipeline](#8-running-the-pipeline)
9. [Observability and Troubleshooting](#9-observability-and-troubleshooting)

---

## 1. Pipeline Overview

```
S3: hr_employees.jsonl (50 records)
        │
        │  aws emr-containers start-job-run
        ▼
EMR Spark job: hr_events_producer.py
        │  df.write.format("kafka")  →  topic: hr-events  (MSK, port 9098, IAM auth)
        ▼
MSK Kafka — topic: hr-events
        │  confluent_kafka.Consumer  (OAUTHBEARER / IAM SASL)
        ▼
kafka-mq-bridge (Deployment, emr-jobs ns)
        │  stomp.Connection.send()   →  /topic/hr.events  (STOMP+SSL, port 61614)
        ▼
Amazon MQ ActiveMQ — /topic/hr.events
        │  stomp.ConnectionListener.on_message()
        ▼
db-writer (Deployment, db-writer ns)
        ├─ opensearch-py   →  hr-employees index   (OpenSearch, HTTPS, SigV4)
        ├─ psycopg2        →  employees table       (Aurora PostgreSQL, port 5432)
        │                     performance_reviews table
        └─ gremlinpython   →  Employee vertices     (Neptune, WSS, SigV4)
                              REPORTS_TO edges
                              HAS_SKILL edges
```

The Spark job is **batch** — it terminates once all records are written to Kafka. The bridge and db-writer are **long-running services** — they run continuously as Kubernetes Deployments.

---

## 2. How Jobs Run on EKS

### Spark job (EMR on EKS)

The Spark job is submitted via `aws emr-containers start-job-run` targeting a virtual cluster that is bound to the `emr-jobs` namespace on `eks-prod`. EMR schedules a Spark driver pod in that namespace under the `emr-job-runner` ServiceAccount. The driver spawns executor pods in the same namespace.

Pod Identity is configured on `emr-job-runner` so that all pods automatically receive short-lived AWS credentials scoped to the `emr-job-runner` IAM role. No access keys or IRSA annotations are required.

```
aws emr-containers start-job-run
    └── Spark driver pod  (namespace: emr-jobs, SA: emr-job-runner)
            └── Executor pods  (namespace: emr-jobs, SA: emr-job-runner)
                    └── IAM credentials via eks-pod-identity-agent (Pod Identity)
```

### kafka-mq-bridge and db-writer (standard Deployments)

Both microservices are Kubernetes Deployments deployed by the prod-data Terraform workspace. They run on `eks-prod` and also use Pod Identity for AWS credentials:

| Deployment | Namespace | ServiceAccount | IAM Role |
|---|---|---|---|
| `kafka-mq-bridge` | `emr-jobs` | `emr-job-runner` | `emr-job-runner` (MSK read/write) |
| `db-writer` | `db-writer` | `db-writer` | `db-writer` (OpenSearch + Neptune) |

Configuration is injected via Kubernetes ConfigMaps and Secrets — the containers themselves contain no hardcoded endpoints or credentials.

---

## 3. Spark Job — `hr_events_producer.py`

### Purpose

Reads the HR employee seed data from S3 and writes each record as a JSON string to the MSK Kafka topic `hr-events`. This is a one-shot batch job that exits cleanly after all records are sent.

### Startup and configuration

```python
# hr_events_producer.py  line 22
spark = SparkSession.builder.appName("HREventsProducer").getOrCreate()

bootstrap_servers = spark.conf.get("spark.kafka.bootstrap.servers")  # line 24
input_path        = spark.conf.get("spark.hr.input.path")            # line 25
```

Both values are injected as `--conf` parameters at job submission time by `scripts/run-pipeline.sh`. They are never hardcoded in the script — the script reads them from Terraform outputs at runtime.

### Reading the seed data

```python
# hr_events_producer.py  line 31
df = spark.read.option("multiline", "false").json(input_path)
```

Spark reads the JSONL file directly from S3. `multiline=false` tells Spark that each line is a complete JSON object (standard JSONL format). Spark infers the schema from the records automatically.

### Serialising rows for Kafka

Kafka messages are key-value pairs where the value must be a byte string. To fit an entire HR event record into one Kafka message value, every DataFrame row is serialised to a single JSON string:

```python
# hr_events_producer.py  lines 35-37
kafka_df = df.select(
    to_json(struct([df[col] for col in df.columns])).alias("value")
)
```

`struct(...)` packs all columns into a single struct column. `to_json(...)` serialises that struct to a JSON string. The result is a single-column DataFrame named `value` — exactly what the Kafka writer expects.

### Writing to MSK with IAM authentication

```python
# hr_events_producer.py  lines 41-56
kafka_df.write.format("kafka")
    .option("kafka.bootstrap.servers", bootstrap_servers)
    .option("topic", "hr-events")
    .option("kafka.security.protocol", "SASL_SSL")
    .option("kafka.sasl.mechanism", "AWS_MSK_IAM")
    .option("kafka.sasl.jaas.config",
            "software.amazon.msk.auth.iam.IAMLoginModule required;")
    .option("kafka.sasl.client.callback.handler.class",
            "software.amazon.msk.auth.iam.IAMClientCallbackHandler")
    .save()
```

The `kafka.sasl.*` options configure MSK IAM authentication. The `aws-msk-iam-auth-2.2.0-all.jar` (uploaded to S3 by `run-pipeline.sh` and referenced via `--conf spark.jars`) provides the `IAMLoginModule` and `IAMClientCallbackHandler` classes. These classes internally call the AWS STS API using the Pod Identity credentials injected into the executor pods. No passwords or certificates are involved.

`df.write.format("kafka").save()` is a **bounded write** — Spark writes all partitions to Kafka and then the job terminates. It does not run a streaming loop.

---

## 4. kafka-mq-bridge — `bridge.py`

### Purpose

A continuously running Python service that:
1. Consumes messages from the MSK `hr-events` Kafka topic
2. Publishes them to Amazon MQ `/topic/hr.events` via STOMP+SSL
3. Commits Kafka offsets only after the STOMP transaction has committed

### Configuration loading

```python
# bridge.py  lines 31-39
KAFKA_BOOTSTRAP_SERVERS = os.environ["KAFKA_BOOTSTRAP_SERVERS"]
KAFKA_TOPIC   = os.environ.get("KAFKA_TOPIC", "hr-events")
KAFKA_GROUP_ID = os.environ.get("KAFKA_GROUP_ID", "kafka-mq-bridge")
MQ_STOMP_URL  = os.environ["MQ_STOMP_URL"]
MQ_DESTINATION = os.environ.get("MQ_DESTINATION", "/topic/hr.events")
MQ_USERNAME   = os.environ["MQ_USERNAME"]
MQ_PASSWORD   = os.environ["MQ_PASSWORD"]
AWS_REGION    = os.environ.get("AWS_REGION", "eu-west-2")
BATCH_SIZE    = int(os.environ.get("BATCH_SIZE", "10"))
```

All values come from the `bridge-config` ConfigMap and `bridge-mq-credentials` Secret in the `emr-jobs` namespace. Nothing is hardcoded.

### MSK IAM token refresh

MSK IAM authentication uses the OAUTHBEARER SASL mechanism. `confluent_kafka` calls the `oauth_cb` function whenever it needs a fresh token:

```python
# bridge.py  lines 44-50
def _msk_oauth_callback(config: dict) -> tuple[str, float]:
    token, expiry_ms = MSKAuthTokenProvider.generate_auth_token(AWS_REGION)
    return token, expiry_ms / 1000   # confluent_kafka expects seconds, not ms
```

`MSKAuthTokenProvider.generate_auth_token()` calls the AWS STS API using the Pod Identity credentials that the `eks-pod-identity-agent` DaemonSet has injected into the pod. The token is an OAUTHBEARER token signed by AWS. `confluent_kafka` caches it and calls this function again before expiry — the application does not need to manage token rotation manually.

### Kafka consumer setup

```python
# bridge.py  lines 55-94
def _kafka_config() -> dict:
    return {
        "bootstrap.servers": KAFKA_BOOTSTRAP_SERVERS,
        "security.protocol": "SASL_SSL",
        "sasl.mechanism": "OAUTHBEARER",
        "oauth_cb": _msk_oauth_callback,
    }

def build_consumer() -> Consumer:
    cfg = _kafka_config()
    cfg.update({
        "group.id": KAFKA_GROUP_ID,
        "auto.offset.reset": "earliest",   # start from the beginning on first run
        "enable.auto.commit": False,        # offsets committed manually after STOMP commit
    })
    return Consumer(cfg)
```

`auto.offset.reset = "earliest"` means if the consumer group has no prior committed offset (e.g. first run), it reads from the start of the topic. `enable.auto.commit = False` is critical — the bridge commits offsets manually only after the corresponding STOMP transaction has been committed, preventing message loss on crash.

### Automatic topic creation

```python
# bridge.py  lines 64-82
def ensure_topic(topic: str) -> None:
    admin = AdminClient(_kafka_config())
    metadata = admin.list_topics(timeout=15)
    if topic in metadata.topics:
        return                             # already exists — nothing to do

    futures = admin.create_topics(
        [NewTopic(topic, num_partitions=3, replication_factor=2)]
    )
    for t, fut in futures.items():
        try:
            fut.result()
        except Exception as exc:
            logger.warning("Could not create topic %s: %s", t, exc)
            # Suppressed — another pod may have created it concurrently
```

On startup, `ensure_topic()` is called before the consumer subscribes. If two bridge pods race to create the topic, the second call is silently suppressed (the `except` block logs a warning and continues).

### STOMP connection and SSL

The MQ_STOMP_URL is a failover URL like `failover:(stomp+ssl://host1:61614,stomp+ssl://host2:61614)?maxReconnectAttempts=10`. The bridge parses the host list before connecting:

```python
# bridge.py  lines 99-114
def _parse_stomp_hosts(failover_url: str) -> list[tuple[str, int]]:
    inner = failover_url.split("(", 1)[1].split(")", 1)[0]
    hosts = []
    for entry in inner.split(","):
        entry = entry.strip().replace("stomp+ssl://", "").replace("stomp://", "")
        host, port_str = entry.rsplit(":", 1)
        hosts.append((host, int(port_str)))
    return hosts
```

The `StompPublisher._connect()` method creates the SSL context and establishes the STOMP connection:

```python
# bridge.py  lines 134-147
def _connect(self) -> None:
    ssl_ctx = ssl.create_default_context()
    ssl_ctx.check_hostname = False      # Amazon MQ uses a private CA inside VPC
    ssl_ctx.verify_mode = ssl.CERT_NONE

    self._conn = stomp.Connection(
        host_and_ports=self._hosts,
        use_ssl=True,
        ssl_context=ssl_ctx,
        reconnect_attempts_max=10,      # stomp.py will retry on disconnect
    )
    self._conn.connect(self._username, self._password, wait=True)
```

`ssl_ctx.verify_mode = ssl.CERT_NONE` skips certificate verification. Amazon MQ uses a private certificate authority; since the pod communicates with MQ entirely within the VPC, hostname verification provides no additional security benefit here.

### Transactional batch publishing

```python
# bridge.py  lines 149-173
def publish_batch(self, messages: list[str], destination: str) -> None:
    tx_id = f"hr-batch-{int(time.monotonic() * 1000)}"
    self._conn.begin(transaction=tx_id)
    try:
        for body in messages:
            self._conn.send(
                destination=destination,
                body=body,
                headers={"content-type": "application/json", "persistent": "true"},
                transaction=tx_id,
            )
        self._conn.commit(transaction=tx_id)     # all-or-nothing delivery
    except Exception:
        self._conn.abort(transaction=tx_id)      # roll back on any error
        raise
```

All messages in a batch are wrapped in a single STOMP transaction. `persistent: true` tells ActiveMQ to persist each message to disk before acknowledging, so messages survive a broker restart. If `commit()` fails, `abort()` discards the whole batch and the exception propagates up to the main loop, which does not commit Kafka offsets — so the messages will be re-delivered by Kafka.

### Main consumer loop

```python
# bridge.py  lines 178-238  (run function)
batch: list[str] = []

while True:
    msg = consumer.poll(timeout=5.0)

    if msg is None:
        # No message for 5 s — flush any partial batch immediately
        if batch:
            publisher.publish_batch(batch, MQ_DESTINATION)
            consumer.commit(asynchronous=False)
            batch = []
        continue

    if msg.error():
        if msg.error().code() == KafkaError._PARTITION_EOF:
            continue                          # normal end of partition — keep polling
        raise KafkaException(msg.error())     # real error — crash and let K8s restart

    batch.append(msg.value().decode("utf-8"))

    if len(batch) >= BATCH_SIZE:
        publisher.publish_batch(batch, MQ_DESTINATION)
        consumer.commit(asynchronous=False)   # only after STOMP commit
        batch = []
```

The loop has two flush conditions:
- **Full batch** (`len(batch) >= BATCH_SIZE`): flush immediately for throughput
- **Idle timeout** (`msg is None` after 5 s): flush partial batch for latency

On shutdown (`KeyboardInterrupt` or pod termination), the `finally` block attempts to flush the remaining partial batch before the consumer closes, avoiding unnecessary reprocessing on restart.

---

## 5. db-writer — `writer.py`

### Purpose

A continuously running Python service that subscribes to Amazon MQ `/topic/hr.events` and writes every HR event to three databases — OpenSearch, Aurora PostgreSQL, and Neptune — before acknowledging the message.

### Startup sequence

```python
# writer.py  lines 410-442  (main function)
os_client  = _build_opensearch_client()
_ensure_os_index(os_client)          # create hr-employees index if absent

aurora_conn = _get_aurora_conn()
_ensure_aurora_schema(aurora_conn)   # CREATE TABLE IF NOT EXISTS

stomp_conn = stomp.Connection(host_and_ports=stomp_hosts, ...)
stomp_conn.set_listener("", HREventListener(stomp_conn, os_client, aurora_conn))
stomp_conn.connect(MQ_USERNAME, MQ_PASSWORD, wait=True)
stomp_conn.subscribe(destination=MQ_DESTINATION, id=1, ack="client-individual")
```

Schema creation (`_ensure_os_index` and `_ensure_aurora_schema`) runs at startup so the service is idempotent on restart — it never fails if the index or tables already exist.

### OpenSearch — SigV4 authentication

```python
# writer.py  lines 87-104
def _build_opensearch_client() -> OpenSearch:
    session = boto3.Session(region_name=AWS_REGION)
    creds = session.get_credentials().get_frozen_credentials()
    auth = AWS4Auth(
        creds.access_key, creds.secret_key, AWS_REGION, "es",
        session_token=creds.token,
    )
    parsed = urlparse(OPENSEARCH_ENDPOINT)
    return OpenSearch(
        hosts=[{"host": parsed.hostname, "port": parsed.port or 443}],
        http_auth=auth, use_ssl=True, verify_certs=True,
        connection_class=RequestsHttpConnection,
    )
```

`boto3.Session` picks up the Pod Identity credentials injected by the `eks-pod-identity-agent`. `AWS4Auth` signs every HTTP request with SigV4. `session_token` is included because Pod Identity provides temporary credentials (not long-lived access keys).

### OpenSearch — index mapping and upsert

```python
# writer.py  lines 107-133  (_ensure_os_index)
# Fields are mapped to explicit types so OpenSearch does not infer them incorrectly:
# - employee_id, email, department → keyword (exact match, not tokenised)
# - full_name                      → text (full-text search) + .raw keyword sub-field
# - salary, performance_score      → float (numeric range queries)
# - hire_date, timestamp           → date
```

```python
# writer.py  lines 136-142  (write_to_opensearch)
def write_to_opensearch(client: OpenSearch, event: dict) -> None:
    client.index(
        index=OS_INDEX,
        id=event["employee_id"],   # document ID = employee_id → upsert semantics
        body=event,
    )
```

Using `employee_id` as the document ID means repeated events for the same employee overwrite the previous document. Each event type (promotion, transfer, etc.) updates the employee's current state — the index always holds the latest snapshot, not a history.

### OpenSearch — Aurora schema

On startup, `_ensure_aurora_schema` creates two tables if they do not exist:

```python
# writer.py  lines 158-185
# employees table:
#   employee_id  TEXT PRIMARY KEY   — unique per employee, upserted on every event
#   skills       TEXT[]             — PostgreSQL native array type
#   updated_at   TIMESTAMPTZ DEFAULT NOW()

# performance_reviews table:
#   event_id     TEXT PRIMARY KEY   — unique per review event
#   employee_id  TEXT NOT NULL      — links back to employees
#   reviewed_at  TIMESTAMPTZ        — taken from event timestamp field
```

### Aurora — upsert logic

```python
# writer.py  lines 188-229  (write_to_aurora)
# Every event updates the employees row (promotion changes job_title and salary,
# transfer changes location, etc.):
cur.execute("""
    INSERT INTO employees (employee_id, full_name, ..., skills, hire_date)
    VALUES (%(employee_id)s, ...)
    ON CONFLICT (employee_id) DO UPDATE SET
        job_title  = EXCLUDED.job_title,
        salary     = EXCLUDED.salary,
        ...
        updated_at = NOW()
""", {**event, "skills": event.get("skills") or []})

# performance_review events also insert into performance_reviews:
if event.get("event_type") == "performance_review" and event.get("performance_score") is not None:
    cur.execute("""
        INSERT INTO performance_reviews (event_id, employee_id, performance_score, reviewed_at)
        VALUES (%(event_id)s, ...)
        ON CONFLICT (event_id) DO UPDATE SET ...
    """, event)
```

The `ON CONFLICT ... DO UPDATE` pattern (PostgreSQL UPSERT) makes every write idempotent — reprocessing the same message after a crash will produce exactly the same database state.

### Neptune — SigV4 WebSocket signing

Neptune IAM authentication requires SigV4 headers to be present in the WebSocket upgrade HTTP request. `gremlinpython` supports injecting custom headers via the `headers` parameter:

```python
# writer.py  lines 234-267
def _get_neptune_headers() -> dict[str, str]:
    session = boto3.Session(region_name=AWS_REGION)
    creds = session.get_credentials().get_frozen_credentials()

    # 1. Convert wss:// → https:// so AWSRequest can parse and sign it
    https_url = NEPTUNE_ENDPOINT.replace("wss://", "https://")
    parsed = urlparse(https_url)

    # 2. Build a request object and sign it with SigV4
    request = AWSRequest(method="GET", url=https_url)
    request.headers["host"] = parsed.hostname
    SigV4Auth(creds, "neptune-db", AWS_REGION).add_auth(request)

    # 3. Extract the auth headers and return them for gremlinpython
    headers = {
        "Authorization":       request.headers["Authorization"],
        "X-Amz-Date":          request.headers["X-Amz-Date"],
        "host":                parsed.hostname,
    }
    if "X-Amz-Security-Token" in request.headers:
        headers["X-Amz-Security-Token"] = request.headers["X-Amz-Security-Token"]
    return headers

def _build_neptune_connection() -> DriverRemoteConnection:
    return DriverRemoteConnection(
        NEPTUNE_ENDPOINT, "g",
        message_serializer=serializer.GraphSONSerializersV2d0(),
        headers=_get_neptune_headers(),    # SigV4 headers on WebSocket upgrade
    )
```

A new connection (and therefore a new signed URL) is opened for each event because SigV4 signatures are time-bound (~15 minutes). Reusing a connection created at startup would cause authentication failures for long-running pods.

### Neptune — graph upsert pattern

Neptune does not support SQL-style `INSERT ... ON CONFLICT`. The standard Gremlin upsert pattern is `coalesce(unfold(), addV(...))`:

```python
# writer.py  lines 283-298  (Employee vertex upsert)
emp_v = (
    g.V()
    .has("Employee", "employee_id", emp_id)   # look up existing vertex
    .fold()                                    # collect into a list (empty if not found)
    .coalesce(
        __.unfold(),                           # if found: unwrap and use it
        __.addV("Employee")                    # if not found: create it
          .property("employee_id", emp_id),
    )
    # Update properties on whichever vertex was found or created:
    .property(Cardinality.single, "full_name", event.get("full_name", ""))
    .property(Cardinality.single, "job_title", event.get("job_title", ""))
    ...
    .next()
)
```

`Cardinality.single` overwrites the existing property value rather than adding a second value alongside it (Neptune supports multi-valued properties by default).

The same `coalesce` pattern is used for edges:

```python
# writer.py  lines 313-324  (REPORTS_TO edge upsert)
g.V(emp_v.id)
 .outE("REPORTS_TO")
 .where(__.inV().hasId(mgr_v.id))   # check if this specific edge already exists
 .fold()
 .coalesce(
     __.unfold(),                    # edge exists — keep it
     __.addE("REPORTS_TO")          # edge absent — create it
       .from_(__.V(emp_v.id))
       .to(__.V(mgr_v.id)),
 )
 .iterate()
```

And for each skill in the event:

```python
# writer.py  lines 327-348  (HAS_SKILL edge per skill)
for skill in event.get("skills") or []:
    skill_v = (
        g.V().has("Skill", "name", skill).fold()
         .coalesce(__.unfold(), __.addV("Skill").property("name", skill))
         .next()
    )
    g.V(emp_v.id).outE("HAS_SKILL").where(__.inV().hasId(skill_v.id))
     .fold().coalesce(__.unfold(), __.addE("HAS_SKILL")
               .from_(__.V(emp_v.id)).to(__.V(skill_v.id)))
     .iterate()
```

### Message acknowledgement — at-least-once delivery

```python
# writer.py  lines 379-405  (HREventListener.on_message)
def on_message(self, frame: stomp.utils.Frame) -> None:
    msg_id     = frame.headers.get("message-id", "unknown")
    subscription = frame.headers.get("subscription", "1")
    try:
        event = json.loads(frame.body)

        write_to_opensearch(self._os, event)   # 1. write to OpenSearch
        write_to_aurora(self._aurora, event)   # 2. write to Aurora
        write_to_neptune(event)                # 3. write to Neptune

        self._conn.ack(msg_id, subscription)   # ACK only after all three succeed
    except Exception as exc:
        logger.exception("Failed to process message %s: %s", msg_id, exc)
        self._conn.nack(msg_id, subscription)  # NACK → ActiveMQ redelivers
```

The ACK is sent **only** if all three writes succeed. If any write fails, the NACK causes ActiveMQ to redeliver the message. Because all three writes are idempotent upserts, redelivery is safe — processing the same message twice produces the same result.

### Reconnect loop

```python
# writer.py  lines 445-455  (main loop)
while True:
    time.sleep(5)
    if not stomp_conn.is_connected():
        stomp_conn.connect(MQ_USERNAME, MQ_PASSWORD, wait=True)
        stomp_conn.subscribe(destination=MQ_DESTINATION, id=1, ack="client-individual")
```

The main thread sleeps in a 5-second loop while the STOMP listener thread (managed internally by `stomp.py`) processes incoming messages. If `stomp.py` drops the connection (e.g. network blip, broker failover), the main thread detects it and reconnects, re-subscribing with the same ACK mode.

---

## 6. Configuration Reference

### kafka-mq-bridge — `bridge-config` ConfigMap + `bridge-mq-credentials` Secret

| Env var | Source | Description |
|---|---|---|
| `KAFKA_BOOTSTRAP_SERVERS` | ConfigMap | MSK IAM bootstrap brokers (port 9098), e.g. `b-1.xxx:9098,b-2.xxx:9098` |
| `KAFKA_TOPIC` | ConfigMap | Kafka topic to consume (default: `hr-events`) |
| `KAFKA_GROUP_ID` | ConfigMap | Consumer group ID (default: `kafka-mq-bridge`) |
| `MQ_STOMP_URL` | ConfigMap | STOMP failover URL, e.g. `failover:(stomp+ssl://h1:61614,...)?maxReconnectAttempts=10` |
| `MQ_DESTINATION` | ConfigMap | STOMP destination (default: `/topic/hr.events`) |
| `MQ_USERNAME` | ConfigMap | Amazon MQ username |
| `AWS_REGION` | ConfigMap | AWS region (default: `eu-west-2`) |
| `BATCH_SIZE` | ConfigMap | Messages per STOMP transaction (default: `10`) |
| `MQ_PASSWORD` | Secret | Amazon MQ password |

### db-writer — `db-endpoints` ConfigMap + Secrets

| Env var | Source | Description |
|---|---|---|
| `MQ_STOMP_URL` | ConfigMap | STOMP failover URL |
| `MQ_DESTINATION` | ConfigMap | STOMP destination (default: `/topic/hr.events`) |
| `MQ_USERNAME` | ConfigMap | Amazon MQ username |
| `OPENSEARCH_ENDPOINT` | ConfigMap | `https://<domain>.<region>.es.amazonaws.com` |
| `NEPTUNE_ENDPOINT` | ConfigMap | `wss://<cluster>.<region>.neptune.amazonaws.com:8182/gremlin` |
| `AURORA_ENDPOINT` | ConfigMap | Aurora cluster write endpoint hostname |
| `AURORA_PORT` | ConfigMap | PostgreSQL port (default: `5432`) |
| `AURORA_DB_NAME` | ConfigMap | Database name (e.g. `proddata`) |
| `AURORA_USERNAME` | ConfigMap | Database username |
| `AWS_REGION` | ConfigMap | AWS region (default: `eu-west-2`) |
| `MQ_PASSWORD` | Secret (`mq-credentials`) | Amazon MQ password |
| `AURORA_PASSWORD` | Secret (`aurora-credentials`) | Aurora master password |

### Spark job — submitted via `--conf`

| Spark conf | Description |
|---|---|
| `spark.jars` | S3 URI of `aws-msk-iam-auth-2.2.0-all.jar` |
| `spark.kafka.bootstrap.servers` | MSK IAM bootstrap brokers |
| `spark.hr.input.path` | S3 URI of `hr_employees.jsonl` |

---

## 7. Building and Deploying the Containers

### kafka-mq-bridge

```bash
docker build -t <registry>/kafka-mq-bridge:latest pipeline/kafka-mq-bridge/
docker push <registry>/kafka-mq-bridge:latest
```

Update `kafka_mq_bridge_image` in `envs/prod-data/terraform.tfvars` and re-apply:

```bash
terraform apply -chdir=envs/prod-data
```

### db-writer

```bash
docker build -t <registry>/db-writer:latest pipeline/db-writer/
docker push <registry>/db-writer:latest
```

Update `db_writer_image` in `envs/prod-data/terraform.tfvars` and re-apply:

```bash
terraform apply -chdir=envs/prod-data
```

> The Dockerfiles use `python:3.11-slim`. The db-writer Dockerfile installs `libpq-dev` and `gcc` at build time (required by `psycopg2-binary`) and removes them afterwards to keep the image small.

---

## 8. Running the Pipeline

### Prerequisites

- `envs/prod` and `envs/prod-data` have been applied (`terraform apply`)
- Both container images have been built, pushed, and set in `terraform.tfvars`
- `kafka-mq-bridge` and `db-writer` pods are running on `eks-prod`

### Submitting the Spark job

```bash
./scripts/run-pipeline.sh
```

What the script does:
1. Downloads `aws-msk-iam-auth-2.2.0-all.jar` from Maven Central to `/tmp/` (cached)
2. Uploads the JAR, seed data, and PySpark script to the EMR S3 landing zone
3. Reads `emr_virtual_cluster_id`, `emr_job_execution_role_arn`, bucket name, and MSK brokers from `terraform output -chdir=envs/prod`
4. Submits the EMR on EKS job
5. Polls every 30 seconds until the job reaches `COMPLETED` or `FAILED`

### Verifying end-to-end

```bash
# 1. Spark job completed
./scripts/run-pipeline.sh   # exits 0 on COMPLETED

# 2. Bridge pod running
kubectl --context prod get pods -n emr-jobs -l app=kafka-mq-bridge

# 3. db-writer pod running
kubectl --context prod get pods -n db-writer -l app=db-writer

# 4. OpenSearch document count (should be 10 — one per employee)
curl -X GET "https://<opensearch-endpoint>/hr-employees/_count" \
  --aws-sigv4 "aws:amz:eu-west-2:es"

# 5. Aurora row counts
psql -h <aurora-endpoint> -U dbadmin -d proddata \
  -c "SELECT COUNT(*) FROM employees;"          -- expected: 10
psql -h <aurora-endpoint> -U dbadmin -d proddata \
  -c "SELECT COUNT(*) FROM performance_reviews;" -- expected: 10

# 6. Neptune vertex count (from Gremlin console)
# g.V().hasLabel('Employee').count()   -- expected: 10 (+ EMP000 manager stub)
# g.E().hasLabel('REPORTS_TO').count() -- expected: 10
# g.E().hasLabel('HAS_SKILL').count()  -- expected: varies by employee
```

---

## 9. Observability and Troubleshooting

### Spark job logs

EMR on EKS writes driver and executor logs to CloudWatch and S3:

```bash
# CloudWatch (tail in real time)
aws logs tail /emr-on-eks/hr-events-producer --follow

# S3 logs
aws s3 ls s3://<landing-zone>/logs/hr-events-producer/ --recursive
```

### kafka-mq-bridge logs

```bash
kubectl --context prod logs -n emr-jobs -l app=kafka-mq-bridge -f
```

Key log lines to look for:

| Log message | Meaning |
|---|---|
| `kafka-mq-bridge starting` | Pod has started |
| `Kafka topic already exists: hr-events` | Topic found on MSK — no creation needed |
| `Connected to Amazon MQ STOMP: [...]` | STOMP connection established |
| `Published batch of 10 message(s) to /topic/hr.events` | Successful batch |
| `Flushed partial batch of N message(s)` | Idle flush (fewer than 10 messages) |
| `Could not create topic hr-events: ...` | Topic creation race — not an error |

### db-writer logs

```bash
kubectl --context prod logs -n db-writer -l app=db-writer -f
```

Key log lines:

| Log message | Meaning |
|---|---|
| `Aurora schema ready` | Tables created or already exist |
| `Created OpenSearch index: hr-employees` | Index created on first run |
| `Processing promotion event for employee EMP001` | Message received from MQ |
| `ACKed message <msg-id>` | All three writes succeeded |
| `Failed to process message <msg-id>` | At least one write failed — message will be redelivered |
| `STOMP disconnected — waiting for reconnect` | MQ broker failover in progress |

### Common issues

| Symptom | Likely cause | Fix |
|---|---|---|
| Spark job stuck in `RUNNING` | MSK bootstrap servers wrong or IAM role missing `kafka-cluster:WriteData` | Check Spark conf via `run-pipeline.sh` output; verify EMR role policy |
| Bridge pod in `CrashLoopBackOff` | `KAFKA_BOOTSTRAP_SERVERS` or `MQ_STOMP_URL` env var missing | Check `bridge-config` ConfigMap; re-apply `envs/prod-data` |
| db-writer pod not ACKing messages | One of the three write functions throwing an exception | Check pod logs; look for `Failed to process message` |
| Neptune `AuthorizationException` | SigV4 token expired or `db-writer` IAM role missing `neptune-db:*` | Verify `aws_iam_role_policy.db_writer` in `envs/prod-data/main.tf` |
| OpenSearch `403 Forbidden` | `db-writer` IAM role not in the domain access policy | Verify `aws_opensearch_domain_policy` grants `es:ESHttp*` to db-writer role ARN |
| Aurora connection refused | VPC peering route missing or security group not open | Check prod-data → prod peering routes and Aurora SG ingress on port 5432 |
