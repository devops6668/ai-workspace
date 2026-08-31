#!/usr/bin/env python3
"""
Send a sample OpenTelemetry trace to Elastic APM Server for verification.

Usage:
    # From within cluster (requires kubectl access)
    python3 send-sample-trace.py

    # With custom endpoint / token
    python3 send-sample-trace.py --endpoint https://apm.luban.paulhome.local:443 \
        --token $(kubectl get secret -n elastic-system apm-server-apm-token \
                   -o jsonpath='{.data.secret-token}' | base64 -d) \
        --ca-bundle /path/to/ca.crt

    # Batch: send 100 traces across multiple services (load test)
    python3 send-sample-trace.py --batch 100 --services api-gateway,user-service,order-service

Dependencies: pip install opentelemetry-api opentelemetry-sdk \
              opentelemetry-exporter-otlp-proto-http
"""
import argparse
import base64
import os
import random
import subprocess
import sys
import time


def get_token_from_k8s():
    """Fetch APM secret token from the ECK-managed secret."""
    result = subprocess.run(
        ["kubectl", "get", "secret", "-n", "elastic-system",
         "apm-server-apm-token", "-o", "jsonpath={.data.secret-token}"],
        capture_output=True, text=True
    )
    if result.returncode != 0 or not result.stdout.strip():
        print("ERROR: Could not fetch APM token. Is kubectl configured?", file=sys.stderr)
        sys.exit(1)
    return base64.b64decode(result.stdout.strip()).decode()


def get_ca_bundle():
    """Fetch the luban CA bundle from kubectl."""
    result = subprocess.run(
        ["kubectl", "get", "secret", "-n", "luban-ci",
         "luban-ca-cert", "-o", "jsonpath={.data.ca\\.crt}"],
        capture_output=True, text=True
    )
    if result.returncode == 0 and result.stdout.strip():
        path = "/tmp/luban-ca-bundle.crt"
        with open(path, "wb") as f:
            f.write(base64.b64decode(result.stdout.strip()))
        return path
    return None


def send_single_trace(endpoint: str, token: str, ca_bundle: str = None):
    """Send a sample trace with parent + child span."""

    os.environ["OTEL_EXPORTER_OTLP_ENDPOINT"] = endpoint
    os.environ["OTEL_EXPORTER_OTLP_PROTOCOL"] = "http/protobuf"
    os.environ["OTEL_EXPORTER_OTLP_HEADERS"] = f"Authorization=Bearer {token}"
    os.environ["OTEL_SERVICE_NAME"] = "trace-verify"

    if ca_bundle:
        os.environ["OTEL_EXPORTER_OTLP_CERTIFICATE"] = ca_bundle

    from opentelemetry import trace
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
    from opentelemetry.sdk.trace.export import BatchSpanProcessor

    provider = TracerProvider()
    exporter = OTLPSpanExporter()
    provider.add_span_processor(BatchSpanProcessor(exporter))
    trace.set_tracer_provider(provider)

    tracer = trace.get_tracer(__name__)
    with tracer.start_as_current_span("hello-world") as span:
        span.set_attribute("test.type", "verification")
        span.set_attribute("test.source", "hermes-agent")
        time.sleep(0.1)
        with tracer.start_as_current_span("child-span") as child:
            child.set_attribute("operation", "verify-apm")
            time.sleep(0.05)

    provider.force_flush()
    print(f"✅ Single trace sent to {endpoint}")
    print(f"   Service: trace-verify  |  Spans: hello-world → child-span")
    print(f"   Check: Kibana → Observability → APM → Services → trace-verify")


def send_batch_traces(endpoint: str, token: str, ca_bundle: str,
                      count: int, services: list[str]):
    """Send N traces across M services for pipeline load verification."""

    os.environ["OTEL_EXPORTER_OTLP_ENDPOINT"] = endpoint
    os.environ["OTEL_EXPORTER_OTLP_PROTOCOL"] = "http/protobuf"
    os.environ["OTEL_EXPORTER_OTLP_HEADERS"] = f"Authorization=Bearer {token}"
    if ca_bundle:
        os.environ["OTEL_EXPORTER_OTLP_CERTIFICATE"] = ca_bundle

    from opentelemetry import trace
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import BatchSpanProcessor
    from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
    from opentelemetry.sdk.resources import Resource

    per_service = count // len(services)
    total = 0
    methods = ["GET", "POST", "PUT", "DELETE"]
    statuses = [200, 200, 200, 201, 500]

    for svc in services:
        resource = Resource.create({"service.name": svc})
        provider = TracerProvider(resource=resource)
        exporter = OTLPSpanExporter()
        processor = BatchSpanProcessor(exporter)
        provider.add_span_processor(processor)
        trace.set_tracer_provider(provider)
        tracer = trace.get_tracer(__name__)

        for i in range(per_service):
            with tracer.start_as_current_span(f"request-{svc}-{i}") as span:
                span.set_attribute("http.method", random.choice(methods))
                span.set_attribute("http.status_code", random.choice(statuses))
                span.set_attribute("test.batch", "true")
                time.sleep(random.uniform(0.01, 0.03))
                with tracer.start_as_current_span("db-query") as child:
                    child.set_attribute("db.system", "postgresql")
                    time.sleep(random.uniform(0.01, 0.03))
            total += 1

        processor.force_flush()
        print(f"  {svc}: {per_service} traces sent")

    print(f"\n✅ {total} traces sent across {len(services)} services")
    print(f"   Check: Kibana → Observability → APM → Services")


def send_duration_traces(endpoint: str, token: str, ca_bundle: str,
                         duration_sec: int, services: list[str]):
    \"\"\"Send traces continuously for a given duration (load test).\"\"\"

    os.environ["OTEL_EXPORTER_OTLP_ENDPOINT"] = endpoint
    os.environ["OTEL_EXPORTER_OTLP_PROTOCOL"] = "http/protobuf"
    os.environ["OTEL_EXPORTER_OTLP_HEADERS"] = f"Authorization=Bearer {token}"
    if ca_bundle:
        os.environ["OTEL_EXPORTER_OTLP_CERTIFICATE"] = ca_bundle

    from opentelemetry import trace
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import BatchSpanProcessor
    from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
    from opentelemetry.sdk.resources import Resource

    methods = ["GET", "POST", "PUT", "DELETE"]
    statuses = [200, 200, 200, 201, 500]
    end_time = time.time() + duration_sec
    total = 0
    batches = 0

    print(f"Continuous load test: {duration_sec}s, {len(services)} services")
    while time.time() < end_time:
        svc = random.choice(services)
        resource = Resource.create({"service.name": svc})
        provider = TracerProvider(resource=resource)
        exporter = OTLPSpanExporter()
        processor = BatchSpanProcessor(exporter)
        provider.add_span_processor(processor)
        trace.set_tracer_provider(provider)
        tracer = trace.get_tracer(__name__)

        n = random.randint(3, 6)
        for i in range(n):
            with tracer.start_as_current_span(f"{svc}-req-{batches}-{i}") as span:
                span.set_attribute("http.method", random.choice(methods))
                span.set_attribute("http.status_code", random.choice(statuses))
                time.sleep(random.uniform(0.01, 0.03))
                with tracer.start_as_current_span("db-query") as child:
                    child.set_attribute("db.system", random.choice(["postgresql", "redis", "es"]))
                    time.sleep(random.uniform(0.01, 0.03))
                with tracer.start_as_current_span("cache-check") as child2:
                    child2.set_attribute("cache.hit", random.choice([True, False]))
                    time.sleep(random.uniform(0.005, 0.02))
            total += n

        processor.force_flush()
        batches += 1
        if batches % 10 == 0:
            remaining = int(end_time - time.time())
            print(f"  {total} traces | {remaining}s remaining")

    print(f"\n✅ {total} traces over {duration_sec}s ({total/duration_sec:.1f}/sec)")
    print(f"   Check: Kibana → Observability → APM")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Send traces to Elastic APM")
    parser.add_argument("--endpoint", default="https://apm.luban.paulhome.local:443")
    parser.add_argument("--token", help="APM secret token")
    parser.add_argument("--ca-bundle", help="Path to CA cert bundle for TLS")
    parser.add_argument("--batch", type=int, default=0,
                        help="Send N traces instead of one")
    parser.add_argument("--duration", type=int, default=0,
                        help="Run for N seconds (continuous load test)")
    parser.add_argument("--services", default="api-gateway,user-service,order-service,payment-service,notification-service",
                        help="Comma-separated service names")
    args = parser.parse_args()

    token = args.token or get_token_from_k8s()
    ca = args.ca_bundle or get_ca_bundle()
    svc_list = [s.strip() for s in args.services.split(",")]

    if args.duration > 0:
        send_duration_traces(args.endpoint, token, ca, args.duration, svc_list)
    elif args.batch > 0:
        send_batch_traces(args.endpoint, token, ca, args.batch, svc_list)
    else:
        send_single_trace(args.endpoint, token, ca)
