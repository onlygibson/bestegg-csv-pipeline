"""CSV processor.

Triggered by SQS. Each SQS message carries an S3 "object created" event.
For every CSV file:
  - valid rows go to DynamoDB
  - rejected rows go to the rejected/ prefix in the same bucket (kept for audit)
  - a summary is published to SNS (email)

Safe to run twice: each row is stored under a fixed key (file + row id),
so a retry overwrites the same item instead of creating a duplicate.
"""

import csv
import io
import json
import os
import urllib.parse
from decimal import Decimal, InvalidOperation

import boto3

s3 = boto3.client("s3")
sns = boto3.client("sns")
dynamodb = boto3.resource("dynamodb")

TABLE_NAME = os.environ["TABLE_NAME"]
TOPIC_ARN = os.environ["TOPIC_ARN"]
INCOMING_PREFIX = os.environ.get("INCOMING_PREFIX", "incoming/")
REJECT_PREFIX = os.environ.get("REJECT_PREFIX", "rejected/")

REQUIRED_FIELDS = ("id", "name", "email", "amount")


def validate(row):
    """Return an error message for a bad row, or None if the row is good."""
    for field in REQUIRED_FIELDS:
        if not (row.get(field) or "").strip():
            return f"missing {field}"
    if "@" not in row["email"]:
        return "bad email"
    try:
        Decimal(row["amount"].strip())
    except InvalidOperation:
        return "bad amount"
    return None


def process_object(bucket, key):
    body = s3.get_object(Bucket=bucket, Key=key)["Body"].read().decode("utf-8-sig")
    reader = csv.DictReader(io.StringIO(body))

    table = dynamodb.Table(TABLE_NAME)
    saved, rejected = 0, []

    with table.batch_writer(overwrite_by_pkeys=["record_id"]) as batch:
        for line_number, row in enumerate(reader, start=2):  # line 1 is the header
            error = validate(row)
            if error:
                rejected.append({**row, "line": line_number, "error": error})
                continue
            batch.put_item(
                Item={
                    "record_id": f"{key}#{row['id'].strip()}",
                    "source_file": key,
                    "name": row["name"].strip(),
                    "email": row["email"].strip(),
                    "amount": Decimal(row["amount"].strip()),
                }
            )
            saved += 1

    if rejected:
        out = io.StringIO()
        writer = csv.DictWriter(
            out, fieldnames=list(REQUIRED_FIELDS) + ["line", "error"], extrasaction="ignore"
        )
        writer.writeheader()
        writer.writerows(rejected)
        file_name = key[len(INCOMING_PREFIX):] if key.startswith(INCOMING_PREFIX) else key
        s3.put_object(Bucket=bucket, Key=REJECT_PREFIX + file_name, Body=out.getvalue().encode())

    sns.publish(
        TopicArn=TOPIC_ARN,
        Subject=f"CSV processed: {key}"[:100],
        Message=f"File {key}: {saved} rows saved, {len(rejected)} rows rejected.",
    )
    log("processed", file=key, saved=saved, rejected=len(rejected))
    return saved, len(rejected)


def handler(event, context):
    """Process a batch of SQS messages. Report only the failed ones, so SQS
    retries those and the good ones are not processed again."""
    failures = []
    for record in event.get("Records", []):
        try:
            message = json.loads(record["body"])
            # S3 sends a one-off "s3:TestEvent" with no Records when the
            # notification is first set up. Nothing to do for that.
            for s3_record in message.get("Records", []):
                bucket = s3_record["s3"]["bucket"]["name"]
                key = urllib.parse.unquote_plus(s3_record["s3"]["object"]["key"])
                process_object(bucket, key)
        except Exception as exc:  # report this message as failed, keep going
            log("failed", messageId=record.get("messageId"), error=str(exc))
            failures.append({"itemIdentifier": record["messageId"]})
    return {"batchItemFailures": failures}


def log(event, **fields):
    print(json.dumps({"event": event, **fields}, default=str))
