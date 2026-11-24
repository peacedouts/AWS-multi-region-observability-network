"""
Cross-region connectivity probe.

Runs inside a HUB VPC (same subnets + SG as the central API), so it exercises
the exact network path the API uses: hub route table -> VPC peering ->
spoke interconnect subnet -> regional gateway ALB (mTLS) -> /healthz.

Every PROBE_INTERVAL seconds for ~one invocation window it measures, per target:
    DNS resolution, TCP connect, TLS handshake, time-to-first-byte, success.

Metrics are high-resolution (1s storage) and are DUAL-WRITTEN to every region
in METRIC_REGIONS, in the monitoring account (via METRIC_ROLE_ARN). Every
hub's probe lands in the same account, so each region holds the full
hub x region matrix and evaluates the correlation alarms on its own: alerting
has no single-region dependency.
"""

import json
import os
import socket
import ssl
import time
from concurrent.futures import ThreadPoolExecutor

import boto3

NAMESPACE = os.environ.get("METRIC_NAMESPACE", "Network/CrossRegion")
SOURCE_HUB = os.environ["SOURCE_HUB"]
TARGETS = json.loads(os.environ["TARGETS"])  # [{"region": "eu", "host": "...", "port": 443, "path": "/healthz"}]
METRIC_REGIONS = json.loads(os.environ["METRIC_REGIONS"])
INTERVAL = int(os.environ.get("PROBE_INTERVAL_SECONDS", "10"))
WINDOW = int(os.environ.get("PROBE_WINDOW_SECONDS", "50"))
TIMEOUT = float(os.environ.get("PROBE_TIMEOUT_SECONDS", "3"))
MTLS_SECRET_ARN = os.environ.get("MTLS_SECRET_ARN", "")
METRIC_ROLE_ARN = os.environ.get("METRIC_ROLE_ARN", "")  # write-only role in the monitoring account

_ssl_ctx = None


def _metric_clients():
    """CloudWatch clients for every metrics region, in the monitoring account when a role is set.
    Called once per invocation so the assumed-role credentials never go stale."""
    creds = {}
    if METRIC_ROLE_ARN:
        c = boto3.client("sts").assume_role(
            RoleArn=METRIC_ROLE_ARN, RoleSessionName=f"connectivity-probe-{SOURCE_HUB}"
        )["Credentials"]
        creds = {
            "aws_access_key_id": c["AccessKeyId"],
            "aws_secret_access_key": c["SecretAccessKey"],
            "aws_session_token": c["SessionToken"],
        }
    return {r: boto3.client("cloudwatch", region_name=r, **creds) for r in METRIC_REGIONS}


def _tls_context():
    """Client TLS context. Verification is always on; mTLS cert loaded from Secrets Manager."""
    global _ssl_ctx
    if _ssl_ctx is not None:
        return _ssl_ctx
    ctx = ssl.create_default_context()
    if MTLS_SECRET_ARN:
        secret = json.loads(
            boto3.client("secretsmanager").get_secret_value(SecretId=MTLS_SECRET_ARN)["SecretString"]
        )
        for name in ("cert", "key", "ca"):
            with open(f"/tmp/{name}.pem", "w") as f:
                f.write(secret[name])
        ctx.load_verify_locations("/tmp/ca.pem")
        ctx.load_cert_chain("/tmp/cert.pem", "/tmp/key.pem")
    _ssl_ctx = ctx
    return ctx


def probe(target):
    host, port, path = target["host"], int(target.get("port", 443)), target.get("path", "/healthz")
    result = {"region": target["region"], "success": 0}
    t0 = time.perf_counter()
    try:
        addr = socket.getaddrinfo(host, port, proto=socket.IPPROTO_TCP)[0][4]
        t_dns = time.perf_counter()
        raw = socket.create_connection(addr[:2], timeout=TIMEOUT)
        t_tcp = time.perf_counter()
        with _tls_context().wrap_socket(raw, server_hostname=host) as tls:
            t_tls = time.perf_counter()
            tls.sendall(f"GET {path} HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n".encode())
            status_line = tls.recv(64).split(b"\r\n", 1)[0]
            t_fb = time.perf_counter()
        status = int(status_line.split()[1])
        result.update(
            DnsMs=(t_dns - t0) * 1000,
            TcpConnectMs=(t_tcp - t_dns) * 1000,
            TlsHandshakeMs=(t_tls - t_tcp) * 1000,
            TimeToFirstByteMs=(t_fb - t_tls) * 1000,
            success=1 if 200 <= status < 300 else 0,
        )
    except Exception as exc:  # any failure is a failed probe; the error class goes to logs
        result["error"] = type(exc).__name__
    return result


def emit(cw_clients, results):
    data = []
    for r in results:
        dims = [{"Name": "SourceHub", "Value": SOURCE_HUB}, {"Name": "TargetRegion", "Value": r["region"]}]
        data.append({"MetricName": "ProbeSuccess", "Dimensions": dims, "Value": r["success"],
                     "Unit": "Count", "StorageResolution": 1})
        for m in ("DnsMs", "TcpConnectMs", "TlsHandshakeMs", "TimeToFirstByteMs"):
            if m in r:
                data.append({"MetricName": m, "Dimensions": dims, "Value": r[m],
                             "Unit": "Milliseconds", "StorageResolution": 1})
    for region, cw in cw_clients.items():
        try:
            cw.put_metric_data(Namespace=NAMESPACE, MetricData=data)
        except Exception as exc:
            # Never let one metrics region break the other; the probe-heartbeat alarm covers this.
            print(json.dumps({"level": "error", "msg": "put_metric_data failed", "region": region,
                              "error": type(exc).__name__}))


def handler(event, context):
    deadline = time.monotonic() + WINDOW
    cw_clients = _metric_clients()
    with ThreadPoolExecutor(max_workers=max(1, len(TARGETS))) as pool:
        while time.monotonic() < deadline:
            started = time.monotonic()
            results = list(pool.map(probe, TARGETS))
            emit(cw_clients, results)
            print(json.dumps({"hub": SOURCE_HUB, "results": results}))
            time.sleep(max(0, INTERVAL - (time.monotonic() - started)))
    return {"ok": True}
