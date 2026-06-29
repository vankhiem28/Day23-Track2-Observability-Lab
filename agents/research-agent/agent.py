"""Day23 research agent — single-shot, OTel-instrumented.

Wraps the day23-inference-api as an LLM tool. Runs N iterations:
  1. think
  2. call a "research tool" (simulated lookup)
  3. call the inference-api to summarize
  4. log structured result

All tool calls emit OTel spans with gen_ai.* attributes; final result
emits a JSON log line tagged with trace_id for Loki correlation.

Designed to run as a k8s Job — short-lived, stateless, retryable.
"""
from __future__ import annotations

import argparse
import json
import os
import random
import sys
import time
import urllib.request
import urllib.error

from opentelemetry import trace
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor, ConsoleSpanExporter
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter

# ---- Telemetry setup ----
resource = Resource.create({
    "service.name": os.getenv("OTEL_SERVICE_NAME", "research-agent"),
    "deployment.environment": os.getenv("DEPLOY_ENV", "lab"),
    "agent.task_type": os.getenv("TASK_TYPE", "research"),
    "agent.run_id": os.getenv("RUN_ID", "unknown"),
})
provider = TracerProvider(resource=resource)
exporter = OTLPSpanExporter(
    endpoint=os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://otel-collector:4317"),
    insecure=True,
)
# Aggressive flushing — short-lived agent runs need spans to ship quickly.
provider.add_span_processor(BatchSpanProcessor(
    exporter,
    max_queue_size=512,
    max_export_batch_size=64,
    schedule_delay_millis=500,
    export_timeout_millis=2000,
))
trace.set_tracer_provider(provider)
tracer = trace.get_tracer("research-agent")


def call_inference_api(prompt: str, model: str = "llama3-mock") -> dict:
    """Call the day23-inference-api as a 'research tool'."""
    with tracer.start_as_current_span("tool.inference_api") as span:
        span.set_attribute("tool.name", "inference_api")
        span.set_attribute("tool.kind", "http")
        url = os.getenv("INFERENCE_URL", "http://inference-api:8000/predict")
        payload = json.dumps({"prompt": prompt, "model": model}).encode()
        req = urllib.request.Request(
            url,
            data=payload,
            headers={"content-type": "application/json"},
        )
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                result = json.loads(resp.read())
        except (urllib.error.URLError, urllib.error.HTTPError) as e:
            span.record_exception(e)
            span.set_status(trace.Status(trace.StatusCode.ERROR, str(e)))
            return {"error": str(e)}

        span.set_attribute("gen_ai.request.model", result.get("model", ""))
        span.set_attribute("gen_ai.usage.input_tokens", result.get("input_tokens", 0))
        span.set_attribute("gen_ai.usage.output_tokens", result.get("output_tokens", 0))
        span.set_attribute("gen_ai.response.id", result.get("trace_id", ""))
        return result


def simulate_search(query: str) -> list[dict]:
    """Simulated web/document search — pretend to be a vector DB lookup."""
    with tracer.start_as_current_span("tool.web_search") as span:
        span.set_attribute("tool.name", "web_search")
        span.set_attribute("tool.kind", "search")
        span.set_attribute("search.query", query)
        time.sleep(random.uniform(0.05, 0.2))
        results = [
            {"title": f"Result {i+1} for '{query}'", "snippet": f"...snippet {i+1}..."}
            for i in range(3)
        ]
        span.set_attribute("search.results_count", len(results))
        return results


def run_research(task: str, iterations: int = 3) -> dict:
    """Execute the agent loop: search → summarize → synthesize."""
    with tracer.start_as_current_span("agent.run") as root_span:
        root_span.set_attribute("agent.task", task)
        root_span.set_attribute("agent.iterations_planned", iterations)

        findings = []
        for i in range(iterations):
            with tracer.start_as_current_span(f"agent.iteration.{i+1}") as iter_span:
                iter_span.set_attribute("agent.iteration", i + 1)
                # 1) Search
                search_results = simulate_search(f"{task} (iteration {i+1})")
                # 2) Summarize via inference-api
                summary_prompt = (
                    f"Task: {task}\n"
                    f"Search results: {json.dumps(search_results)}\n"
                    f"Summarize key insight in 1 sentence."
                )
                summary = call_inference_api(summary_prompt)
                findings.append(summary)
                iter_span.set_attribute("agent.finding.text", str(summary)[:200])

        # 3) Final synthesis
        with tracer.start_as_current_span("agent.synthesize"):
            final_prompt = (
                f"Original task: {task}\n"
                f"Per-iteration findings: {json.dumps(findings)[:2000]}\n"
                f"Produce final synthesis (2-3 sentences)."
            )
            final = call_inference_api(final_prompt)

        root_span.set_attribute("agent.total_findings", len(findings))
        root_span.set_attribute("agent.total_tokens", sum(
            (f.get("input_tokens", 0) + f.get("output_tokens", 0)) for f in findings if isinstance(f, dict)
        ))

        return {
            "task": task,
            "iterations": iterations,
            "findings": findings,
            "final": final,
        }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--task", default=os.getenv("TASK", "Research: top vector DBs in 2026"))
    parser.add_argument("--iterations", type=int, default=int(os.getenv("ITERATIONS", "3")))
    args = parser.parse_args()

    run_id = os.getenv("RUN_ID", f"run-{random.randint(1000,9999)}")
    print(json.dumps({
        "event": "agent.start",
        "run_id": run_id,
        "task": args.task,
        "iterations": args.iterations,
        "trace_id": format(trace.get_current_span().get_span_context().trace_id, "032x"),
    }), flush=True)

    result = run_research(args.task, args.iterations)

    print(json.dumps({
        "event": "agent.complete",
        "run_id": run_id,
        "task": args.task,
        "iterations": args.iterations,
        "final_text": result.get("final", {}).get("text", ""),
        "total_tokens": sum(
            (f.get("input_tokens", 0) + f.get("output_tokens", 0))
            for f in result.get("findings", []) if isinstance(f, dict)
        ),
    }), flush=True)

    # Force flush remaining spans before shutdown (BatchSpanProcessor has 5s default delay).
    provider.force_flush(timeout_millis=5000)
    provider.shutdown()
    return 0


if __name__ == "__main__":
    sys.exit(main())