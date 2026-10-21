"""Validate the frozen schemas, task scope and tool responses before forwarding."""

import hashlib
import json
import math
import re
from pathlib import Path

from bailian_client import ROOT, REGISTERED_NAMES, load_tools, read_json


class GuardError(Exception):
    pass


def strict_json(text):
    def pairs(items):
        value = {}
        for key, item in items:
            if key in value:
                raise GuardError("DUPLICATE_JSON_KEY")
            value[key] = item
        return value

    def constant(_):
        raise GuardError("NONFINITE_JSON_NUMBER")

    try:
        return json.loads(text, object_pairs_hook=pairs, parse_constant=constant)
    except (TypeError, ValueError, RecursionError):
        raise GuardError("INVALID_ARGUMENT_JSON") from None


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False)


def validate_schema(value, schema):
    kind = schema.get("type")
    if kind == "object":
        if not isinstance(value, dict):
            raise GuardError("ARGUMENT_SCHEMA_MISMATCH")
        properties = schema.get("properties", {})
        if not set(schema.get("required", [])).issubset(value):
            raise GuardError("MISSING_REQUIRED_ARGUMENT")
        if schema.get("additionalProperties") is False and set(value) - set(properties):
            raise GuardError("EXTRA_ARGUMENT")
        for key, child in value.items():
            if key in properties:
                validate_schema(child, properties[key])
    elif kind == "string":
        if not isinstance(value, str) or ("pattern" in schema and not re.fullmatch(schema["pattern"], value)):
            raise GuardError("ARGUMENT_SCHEMA_MISMATCH")
    elif kind == "number":
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
            raise GuardError("ARGUMENT_SCHEMA_MISMATCH")
        if "minimum" in schema and value < schema["minimum"]:
            raise GuardError("ARGUMENT_SCHEMA_MISMATCH")
    elif kind == "array":
        if not isinstance(value, list) or not schema.get("minItems", 0) <= len(value) <= schema.get("maxItems", math.inf):
            raise GuardError("ARGUMENT_SCHEMA_MISMATCH")
        if schema.get("uniqueItems") and len({canonical(v) for v in value}) != len(value):
            raise GuardError("DUPLICATE_ARRAY_ITEM")
        for child in value:
            validate_schema(child, schema["items"])
    else:
        raise GuardError("UNSUPPORTED_SCHEMA_TYPE")
    if "enum" in schema and value not in schema["enum"]:
        raise GuardError("ARGUMENT_ENUM_MISMATCH")


def validate_response(response, tool, case_id, expected_version=None):
    if not isinstance(response, dict) or response.get("tool") != tool:
        raise GuardError("TOOL_RESPONSE_IDENTITY_MISMATCH")
    if response.get("case_id") not in (case_id, ""):
        raise GuardError("TOOL_RESPONSE_CASE_MISMATCH")
    if response.get("status") not in {"ok", "insufficient_data", "not_applicable", "execution_error"}:
        raise GuardError("TOOL_RESPONSE_STATUS_INVALID")
    if expected_version is not None and response.get("tool_version") != expected_version:
        raise GuardError("TOOL_RESPONSE_VERSION_MISMATCH")
    if response["status"] == "ok" and tool != "lookup_method_conditions" and response.get("case_id") != case_id:
        raise GuardError("TOOL_RESPONSE_CASE_MISMATCH")
    for field in ("tool_version", "error_code", "input_hash", "preconditions", "result", "evidence", "warnings", "duration_ms"):
        if field not in response:
            raise GuardError("TOOL_RESPONSE_FIELD_MISSING")

    def walk(value):
        if isinstance(value, dict):
            for key, child in value.items():
                if key in {"config", "appliedFault", "reference_class", "source_run_id", "ground_truth"} or key.startswith("injected_"):
                    raise GuardError("PRIVATE_FIELD_IN_TOOL_RESPONSE")
                walk(child)
        elif isinstance(value, list):
            for child in value:
                walk(child)
        elif isinstance(value, str):
            if re.search(r"(?<![A-Za-z0-9_])[A-Za-z]:[\\/]|evaluation_private|legacy_private|source_snapshot", value):
                raise GuardError("PRIVATE_PATH_IN_TOOL_RESPONSE")
        elif isinstance(value, float) and not math.isfinite(value):
            raise GuardError("NONFINITE_TOOL_RESPONSE")

    walk(response)


def rejected(tool, case_id, code):
    # Fixed error vocabulary, never echo rejected paths/arguments or exceptions.
    return {"tool": tool if tool in REGISTERED_NAMES else "",
        "tool_version": "", "case_id": case_id, "status": "execution_error", "error_code": code,
        "input_hash": "", "preconditions": [], "result": {}, "evidence": [],
        "warnings": ["EXECUTOR_REJECTED_CALL"], "duration_ms": 0}


class ToolExecutor:
    def __init__(self, case_id, backend, tools=None, registry_dir=None):
        self.case_id = case_id
        self.backend = backend
        self.registry_dir = Path(registry_dir or ROOT / "tools/registry").resolve()
        self.tools = tools or load_tools(self.registry_dir)
        self.schemas = {t["function"]["name"]: t["function"]["parameters"] for t in self.tools}
        registry = read_json(self.registry_dir / "tool_registry_v1.json")
        release_kind = "legacy"
        if registry["registry_version"] == "EMA-TOOLS-STAGE4-1.1":
            boundary = read_json(ROOT / "tools/registry_stage4/boundary_release_index.json")
            if case_id in {c["case_id"] for c in boundary["cases"]}:
                release_kind = "boundary"
        self.versions = {t["name"]: t.get("response_versions", {}).get(release_kind, t["version"])
                         for t in registry["tools"]}
        self.inspected = False
        self.owned_bundles = set()
        self.seen = set()
        self.records = []
        self.backend_calls = 0

    def execute(self, name, arguments_text, timeout_s=45):
        record = {"tool": name if name in self.schemas else "", "backend_executed": False}
        try:
            if name not in self.schemas:
                raise GuardError("UNREGISTERED_TOOL")
            args = strict_json(arguments_text)
            validate_schema(args, self.schemas[name])
            if "case_id" in args and args["case_id"] != self.case_id:
                raise GuardError("CROSS_CASE_ACCESS")
            for field in ("analysis_interval_s", "time_range_s"):
                if field in args and args[field][0] > args[field][1]:
                    raise GuardError("REVERSED_TIME_INTERVAL")
            if name == "compute_residual_bundle" and not self.inspected:
                raise GuardError("INSPECTION_REQUIRED")
            if name in {"locate_anomalies", "plot_evidence"} and args["residual_evidence_id"] not in self.owned_bundles:
                raise GuardError("BUNDLE_NOT_OBTAINED_IN_THIS_RUN")
            fingerprint = hashlib.sha256((name + canonical(args)).encode("utf-8")).hexdigest()
            if fingerprint in self.seen:
                raise GuardError("DUPLICATE_TOOL_CALL")
            self.seen.add(fingerprint)
            record.update({"arguments": args, "request_fingerprint": fingerprint, "backend_executed": True})
            self.backend_calls += 1
            response = self.backend.call(name, args, timeout_s=timeout_s)
            validate_response(response, name, self.case_id, self.versions[name])
            if name in {"locate_anomalies", "plot_evidence"} and response["status"] == "ok":
                if response["result"].get("residual_evidence_id") != args["residual_evidence_id"]:
                    raise GuardError("TOOL_RESPONSE_BUNDLE_MISMATCH")
            if name == "inspect_case" and response["status"] == "ok":
                self.inspected = True
            if name == "compute_residual_bundle" and response["status"] == "ok":
                bundle = response["result"].get("bundle_id", "")
                if not re.fullmatch(r"BUNDLE-[0-9a-f]{64}", bundle):
                    raise GuardError("INVALID_BUNDLE_FROM_TOOL")
                self.owned_bundles.add(bundle)
        except GuardError as error:
            response = rejected(name, self.case_id, str(error))
        except Exception:
            response = rejected(name, self.case_id, "BACKEND_EXECUTION_FAILED")
        record["response"] = response
        self.records.append(record)
        return response
