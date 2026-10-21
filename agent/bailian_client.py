"""Minimal Bailian transport and schema loader; no MATLAB or private-data access."""

import hashlib
import json
import os
from pathlib import Path
import re
import urllib.error
import urllib.request
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
REGISTERED_NAMES = {
    "inspect_case", "compute_residual_bundle", "locate_anomalies",
    "query_operating_context", "lookup_method_conditions", "plot_evidence",
}


class ClientError(Exception):
    """Errors contain fixed codes only; never request headers or server echoes."""

    def __init__(self, code, details=None):
        super().__init__(code)
        self.details = details or {}


def read_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8-sig"))


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def load_config():
    config = read_json(ROOT / "configs/llm_provider.json")
    if config.get("provider") == "deepseek_official":
        from deepseek_client import validate_config
        return validate_config(config)
    parsed = urlsplit(config["base_url"])
    if (parsed.scheme != "https" or parsed.username or parsed.password
            or parsed.port not in (None, 443) or parsed.query or parsed.fragment
            or parsed.path != "/compatible-mode/v1"
            or not re.fullmatch(r"ws-[a-z0-9]+\.cn-beijing\.maas\.aliyuncs\.com",
                                parsed.hostname or "")):
        raise ClientError("UNAPPROVED_ENDPOINT")
    if config["provider"] != "aliyun_bailian" or config["api_key_env"] != "DASHSCOPE_API_KEY":
        raise ClientError("UNAPPROVED_PROVIDER_OR_CREDENTIAL_SOURCE")
    return config


def read_api_key(env_name=None):
    """Allow current process or Windows user env; do not print or persist key."""
    if env_name is None:
        env_name = load_config()["api_key_env"]
    if env_name not in {"DASHSCOPE_API_KEY", "DEEPSEEK_API_KEY"}:
        raise ClientError("UNAPPROVED_CREDENTIAL_SOURCE")
    value = os.environ.get(env_name, "").strip()
    if value:
        return value
    if os.name == "nt":
        import winreg
        try:
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment") as handle:
                value, _ = winreg.QueryValueEx(handle, env_name)
                if isinstance(value, str):
                    return value.strip()
        except OSError:
            pass
    return ""


def load_tools(registry_dir=None):
    folder = Path(registry_dir or ROOT / "tools/registry").resolve()
    registry = read_json(folder / "tool_registry_v1.json")
    entries = registry["tools"]
    if (registry["registry_version"] not in {"EMA-TOOLS-1.0", "EMA-TOOLS-STAGE4-1.1"} or len(entries) != 6
            or {e["name"] for e in entries} != REGISTERED_NAMES):
        raise ClientError("REGISTRY_SCOPE_MISMATCH")
    tools = []
    for entry in entries:
        path = (folder / entry["schema_file"]).resolve()
        if path.parent != folder:
            raise ClientError("SCHEMA_PATH_OUTSIDE_REGISTRY")
        if sha256(path) != entry["schema_sha256"]:
            raise ClientError("SCHEMA_HASH_MISMATCH")
        schema = read_json(path)
        if schema["name"] != entry["name"] or schema["version"] != entry["version"]:
            raise ClientError("SCHEMA_IDENTITY_MISMATCH")
        tools.append({"type": "function", "function": {
            "name": entry["name"], "description": schema["description"],
            "parameters": schema["parameters"],
        }})
    return tools


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, file_pointer, code, message, headers, new_url):
        raise ClientError("REDIRECT_REFUSED")


def chat_completion(config, messages, *, tools=None, tool_choice=None, max_tokens=256, timeout_s=60):
    """One request, no automatic retry; caller owns the explicit call budget."""
    if config.get("provider") == "deepseek_official":
        from deepseek_client import chat_completion as official_completion
        return official_completion(config, messages, tools=tools, tool_choice=tool_choice,
                                   max_tokens=max_tokens, timeout_s=timeout_s)
    key = read_api_key("DASHSCOPE_API_KEY")
    if not key:
        raise ClientError("MISSING_API_KEY")
    model = config.get("model")
    if not model:
        raise ClientError("MISSING_MODEL")
    settings = config["generation_settings"]
    payload = {
        "model": model, "messages": messages, "stream": False,
        "temperature": settings["temperature"],
        "max_tokens": max_tokens, "enable_thinking": settings["enable_thinking"],
    }
    if tools is not None:
        if {t["function"]["name"] for t in tools} != REGISTERED_NAMES or len(tools) != 6:
            raise ClientError("UNREGISTERED_TOOL_SET")
        payload["tools"] = tools
    if tool_choice is not None:
        payload["tool_choice"] = tool_choice
    request = urllib.request.Request(
        config["base_url"] + "/chat/completions",
        data=json.dumps(payload, ensure_ascii=False, allow_nan=False).encode("utf-8"),
        headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"},
        method="POST",
    )
    try:
        opener = urllib.request.build_opener(NoRedirect())
        with opener.open(request, timeout=min(120, max(0.1, timeout_s))) as response:
            content = response.read(2_000_001)
        if len(content) > 2_000_000:
            raise ClientError("RESPONSE_TOO_LARGE")
        result = json.loads(content)
        if not isinstance(result.get("choices"), list) or not result["choices"]:
            raise ClientError("INVALID_RESPONSE_ENVELOPE")
        return payload, result
    except urllib.error.HTTPError as error:
        details = {"http_status": error.code}
        # Read only a bounded error body and retain a validated provider CODE,
        # never its free-text message, request body or credential headers.
        try:
            data = json.loads(error.read(4096))
            info = data.get("error", data)
            code = info.get("code", info.get("Code", ""))
            if (isinstance(code, str) and re.fullmatch(r"[A-Za-z][A-Za-z0-9_.-]{0,79}", code)
                    and not code.startswith("sk-") and key not in code):
                details["provider_error_code"] = code
        except (ValueError, AttributeError, OSError):
            pass
        raise ClientError("HTTP_" + str(error.code), details) from None
    except (urllib.error.URLError, TimeoutError, OSError):
        raise ClientError("NETWORK_OR_TIMEOUT") from None
    except (ValueError, KeyError, TypeError):
        raise ClientError("INVALID_RESPONSE_JSON") from None
