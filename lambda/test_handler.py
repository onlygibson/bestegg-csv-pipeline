"""Local tests. AWS is faked with moto, so these run without an AWS account:

    pip install -r lambda/requirements-dev.txt
    pytest -q lambda
"""

import importlib
import json
import sys
from pathlib import Path

import boto3
import pytest
from moto import mock_aws

BUCKET = "test-incoming"
TABLE = "test-records"
SAMPLE = Path(__file__).resolve().parent.parent / "sample" / "customers.csv"


@pytest.fixture
def aws(monkeypatch):
    monkeypatch.setenv("AWS_DEFAULT_REGION", "us-east-1")
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "testing")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "testing")
    monkeypatch.setenv("TABLE_NAME", TABLE)
    with mock_aws():
        s3 = boto3.client("s3")
        s3.create_bucket(Bucket=BUCKET)
        boto3.client("dynamodb").create_table(
            TableName=TABLE,
            KeySchema=[{"AttributeName": "record_id", "KeyType": "HASH"}],
            AttributeDefinitions=[{"AttributeName": "record_id", "AttributeType": "S"}],
            BillingMode="PAY_PER_REQUEST",
        )
        topic_arn = boto3.client("sns").create_topic(Name="test-topic")["TopicArn"]
        monkeypatch.setenv("TOPIC_ARN", topic_arn)

        # Import after the fake AWS and env vars are ready.
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        import handler

        yield importlib.reload(handler), s3


def sqs_event(key, message_id="msg-1"):
    s3_event = {"Records": [{"s3": {"bucket": {"name": BUCKET}, "object": {"key": key}}}]}
    return {"Records": [{"messageId": message_id, "body": json.dumps(s3_event)}]}


def count_items():
    return boto3.client("dynamodb").scan(TableName=TABLE)["Count"]


def test_good_rows_saved_bad_rows_rejected(aws):
    handler, s3 = aws
    s3.put_object(Bucket=BUCKET, Key="incoming/customers.csv", Body=SAMPLE.read_bytes())

    result = handler.handler(sqs_event("incoming/customers.csv"), None)

    assert result == {"batchItemFailures": []}
    assert count_items() == 2

    rejected = s3.get_object(Bucket=BUCKET, Key="rejected/customers.csv")["Body"].read().decode()
    assert rejected.count("\n") == 4  # header + 3 rejected rows
    assert "missing name" in rejected
    assert "bad email" in rejected
    assert "bad amount" in rejected


def test_running_twice_does_not_duplicate(aws):
    handler, s3 = aws
    s3.put_object(Bucket=BUCKET, Key="incoming/customers.csv", Body=SAMPLE.read_bytes())

    handler.handler(sqs_event("incoming/customers.csv"), None)
    handler.handler(sqs_event("incoming/customers.csv"), None)

    assert count_items() == 2


def test_failed_message_is_reported_for_retry(aws):
    handler, _ = aws
    # The file does not exist, so this message fails and must be retried.
    result = handler.handler(sqs_event("incoming/missing.csv", message_id="msg-bad"), None)

    assert result == {"batchItemFailures": [{"itemIdentifier": "msg-bad"}]}


def test_s3_test_event_is_ignored(aws):
    handler, _ = aws
    event = {"Records": [{"messageId": "msg-test", "body": json.dumps({"Event": "s3:TestEvent"})}]}

    assert handler.handler(event, None) == {"batchItemFailures": []}
