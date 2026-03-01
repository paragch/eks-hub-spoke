"""
hr_events_producer.py — PySpark batch job that reads the HR seed data JSONL
from S3 and writes each record as a JSON string to the MSK Kafka topic
`hr-events`.

Usage (submitted via EMR on EKS):
    spark-submit \
        --conf spark.jars=s3://<bucket>/jars/aws-msk-iam-auth-2.2.0-all.jar \
        --conf spark.kafka.bootstrap.servers=<broker1>:9098,<broker2>:9098 \
        --conf spark.hr.input.path=s3://<bucket>/seed-data/hr_employees.jsonl \
        hr_events_producer.py

MSK IAM authentication uses the aws-msk-iam-auth-2.2.0-all.jar which must be
on the Spark executor classpath (passed via --conf spark.jars above).
"""

from pyspark.sql import SparkSession
from pyspark.sql.functions import to_json, struct


def main() -> None:
    spark = SparkSession.builder.appName("HREventsProducer").getOrCreate()

    bootstrap_servers = spark.conf.get("spark.kafka.bootstrap.servers")
    input_path = spark.conf.get("spark.hr.input.path")

    print(f"Reading HR seed data from: {input_path}")
    print(f"Writing to MSK bootstrap servers: {bootstrap_servers}")

    # Read JSONL — infer schema from the JSON records
    df = spark.read.option("multiline", "false").json(input_path)
    print(f"Loaded {df.count()} HR event records")

    # Serialise every row to a single JSON string so it fits in one Kafka value
    kafka_df = df.select(
        to_json(struct([df[col] for col in df.columns])).alias("value")
    )

    # Write to Kafka — df.write.format("kafka") terminates after all rows are sent
    (
        kafka_df.write.format("kafka")
        .option("kafka.bootstrap.servers", bootstrap_servers)
        .option("topic", "hr-events")
        # MSK IAM authentication
        .option("kafka.security.protocol", "SASL_SSL")
        .option("kafka.sasl.mechanism", "AWS_MSK_IAM")
        .option(
            "kafka.sasl.jaas.config",
            "software.amazon.msk.auth.iam.IAMLoginModule required;",
        )
        .option(
            "kafka.sasl.client.callback.handler.class",
            "software.amazon.msk.auth.iam.IAMClientCallbackHandler",
        )
        .save()
    )

    print("All HR events successfully written to Kafka topic: hr-events")
    spark.stop()


if __name__ == "__main__":
    main()
