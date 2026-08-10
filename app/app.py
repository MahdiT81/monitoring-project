import random
import time

from flask import Flask, jsonify
from prometheus_client import Counter, Gauge, Histogram, generate_latest, CONTENT_TYPE_LATEST

app = Flask(__name__)

REQUEST_COUNT = Counter(
    "app_http_requests_total",
    "Total HTTP requests",
    ["method", "endpoint", "status"],
)

REQUEST_LATENCY = Histogram(
    "app_http_request_duration_seconds",
    "HTTP request latency in seconds",
    ["endpoint"],
    buckets=(0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0),
)

IN_PROGRESS = Gauge(
    "app_http_requests_in_progress",
    "HTTP requests currently being served",
    ["endpoint"],
)

APP_INFO = Gauge(
    "app_info",
    "Application metadata",
    ["version"],
)

APP_INFO.labels(version="1.0.0").set(1)


@app.before_request
def before_request():
    from flask import request

    request._start_time = time.time()
    if request.path != "/metrics":
        IN_PROGRESS.labels(endpoint=request.path).inc()


@app.after_request
def after_request(response):
    from flask import request

    if request.path == "/metrics":
        return response

    endpoint = request.path
    REQUEST_COUNT.labels(
        method=request.method,
        endpoint=endpoint,
        status=response.status_code,
    ).inc()
    IN_PROGRESS.labels(endpoint=endpoint).dec()
    REQUEST_LATENCY.labels(endpoint=endpoint).observe(time.time() - request._start_time)
    return response


@app.route("/")
def index():
    time.sleep(random.uniform(0.01, 0.08))
    return jsonify(service="webapp", status="ok")


@app.route("/api/users")
def users():
    time.sleep(random.uniform(0.02, 0.15))
    return jsonify(users=["alice", "bob", "carol"])


@app.route("/api/orders")
def orders():
    # Simulates an unstable endpoint: ~10% of requests fail
    time.sleep(random.uniform(0.05, 0.4))
    if random.random() < 0.10:
        return jsonify(error="internal error"), 500
    return jsonify(orders=[{"id": 1}, {"id": 2}])


@app.route("/api/slow")
def slow():
    # Deliberately slow endpoint to exercise latency alerts
    time.sleep(random.uniform(1.0, 3.0))
    return jsonify(message="that took a while")


@app.route("/health")
def health():
    return jsonify(status="ok")


@app.route("/metrics")
def metrics():
    return generate_latest(), 200, {"Content-Type": CONTENT_TYPE_LATEST}


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
