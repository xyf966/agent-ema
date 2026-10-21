"""DeepSeek official endpoint; its own credential only, with no provider fallback."""
import json
import urllib.error
import urllib.request

from bailian_client import ClientError, NoRedirect, REGISTERED_NAMES, read_api_key


def validate_config(config):
    if (config.get('provider') != 'deepseek_official'
            or config.get('base_url') != 'https://api.deepseek.com'
            or config.get('api_key_env') != 'DEEPSEEK_API_KEY'):
        raise ClientError('UNAPPROVED_DEEPSEEK_ENDPOINT_OR_CREDENTIAL_SOURCE')
    if config.get('model') != 'deepseek-flash':
        raise ClientError('UNCONFIRMED_DEEPSEEK_MODEL')
    # The existing loop does not replay reasoning_content. Keep thinking off
    # explicitly; enabling it needs a separately validated tool-message adapter.
    if config['generation_settings'].get('enable_thinking') is not False:
        raise ClientError('DEEPSEEK_THINKING_TOOL_REPLAY_NOT_CONFIGURED')
    return config


def chat_completion(config, messages, *, tools=None, tool_choice=None, max_tokens=256, timeout_s=60):
    validate_config(config)
    key = read_api_key('DEEPSEEK_API_KEY')
    if not key:
        raise ClientError('MISSING_DEEPSEEK_API_KEY')
    payload = {'model':config['model'], 'messages':messages, 'stream':False,
               'temperature':config['generation_settings']['temperature'],
               'max_tokens':max_tokens, 'thinking':{'type':'disabled'}}
    if tools is not None:
        if len(tools) != 6 or {t['function']['name'] for t in tools} != REGISTERED_NAMES:
            raise ClientError('UNREGISTERED_TOOL_SET')
        payload['tools'] = tools
    if tool_choice is not None:
        payload['tool_choice'] = tool_choice
    request = urllib.request.Request('https://api.deepseek.com/chat/completions',
        data=json.dumps(payload, ensure_ascii=False, allow_nan=False).encode('utf-8'),
        headers={'Authorization':'Bearer '+key, 'Content-Type':'application/json'}, method='POST')
    try:
        opener = urllib.request.build_opener(NoRedirect())
        with opener.open(request, timeout=min(120, max(0.1, timeout_s))) as response:
            raw = response.read(2_000_001)
        if len(raw) > 2_000_000:
            raise ClientError('RESPONSE_TOO_LARGE')
        result = json.loads(raw)
        if not isinstance(result.get('choices'), list) or not result['choices']:
            raise ClientError('INVALID_RESPONSE_ENVELOPE')
        return payload, result
    except urllib.error.HTTPError as error:
        # Never persist server messages, headers or request/credential echoes.
        raise ClientError('DEEPSEEK_HTTP_'+str(error.code), {'http_status':error.code}) from None
    except (urllib.error.URLError, TimeoutError, OSError):
        raise ClientError('DEEPSEEK_NETWORK_OR_TIMEOUT') from None
    except (ValueError, KeyError, TypeError):
        raise ClientError('INVALID_RESPONSE_JSON') from None
