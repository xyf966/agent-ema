"""Project-local llama.cpp transport, restricted to the loopback endpoint."""

import json
import urllib.error
import urllib.request

from bailian_client import ROOT, ClientError, NoRedirect, REGISTERED_NAMES, read_json


CONFIG_PATH = ROOT / "configs/llm_local_qwen35_4b.json"


def load_config():
    config = read_json(CONFIG_PATH)
    if (config.get("base_url") != "http://127.0.0.1:8087/v1"
            or config.get("provider") != "local_llama_cpp"
            or config.get("model") != "qwen3.5-4b-q4_k_m"):
        raise ClientError("UNAPPROVED_LOCAL_ENDPOINT_OR_MODEL")
    return config


def chat_completion(config, messages, *, tools=None, tool_choice=None,
                    max_tokens=8192, timeout_s=120):
    if (config.get("base_url") != "http://127.0.0.1:8087/v1"
            or config.get("provider") != "local_llama_cpp"
            or config.get("model") != "qwen3.5-4b-q4_k_m"):
        raise ClientError("UNAPPROVED_LOCAL_ENDPOINT_OR_MODEL")
    settings = config["generation_settings"]
    payload = {
        "model": config["model"], "messages": messages, "stream": False,
        "temperature": settings["temperature"], "top_p": settings["top_p"],
        "top_k": settings["top_k"], "max_tokens": max_tokens,
        "chat_template_kwargs": {"enable_thinking": settings["enable_thinking"]},
    }
    if tools is not None:
        if len(tools) != 6 or {t["function"]["name"] for t in tools} != REGISTERED_NAMES:
            raise ClientError("UNREGISTERED_TOOL_SET")
        payload["tools"] = tools
    expected_tool = None
    if isinstance(tool_choice, dict):
        expected_tool = tool_choice.get("function", {}).get("name")
        if tool_choice.get("type") != "function" or expected_tool not in REGISTERED_NAMES or tools is None:
            raise ClientError("INVALID_LOCAL_TOOL_CHOICE")
        # This pinned llama.cpp release accepts string choices only. Require a
        # call server-side, then reject any name other than the requested one.
        payload["tool_choice"] = "required"
    elif tool_choice is not None:
        if tool_choice not in {"auto", "none", "required"}:
            raise ClientError("INVALID_LOCAL_TOOL_CHOICE")
        payload["tool_choice"] = tool_choice
    request = urllib.request.Request(config["base_url"] + "/chat/completions",
        data=json.dumps(payload, ensure_ascii=False, allow_nan=False).encode("utf-8"),
        headers={"Content-Type": "application/json"}, method="POST")
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    try:
        with opener.open(request, timeout=max(0.1, min(600, timeout_s))) as response:
            raw = response.read(2_000_001)
        if len(raw) > 2_000_000:
            raise ClientError("RESPONSE_TOO_LARGE")
        result = json.loads(raw)
        if not isinstance(result.get("choices"), list) or not result["choices"]:
            raise ClientError("INVALID_RESPONSE_ENVELOPE")
        if result.get("model") != config["model"]:
            raise ClientError("LOCAL_MODEL_IDENTITY_MISMATCH")
        if expected_tool:
            calls = result["choices"][0]["message"].get("tool_calls") or []
            if len(calls) != 1 or calls[0].get("function", {}).get("name") != expected_tool:
                raise ClientError("UNEXPECTED_FORCED_TOOL")
        return payload, result
    except urllib.error.HTTPError as error:
        raise ClientError("LOCAL_HTTP_" + str(error.code)) from None
    except (urllib.error.URLError, TimeoutError, OSError):
        raise ClientError("LOCAL_NETWORK_OR_TIMEOUT") from None
    except (ValueError, KeyError, TypeError):
        raise ClientError("INVALID_RESPONSE_JSON") from None
