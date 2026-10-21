"""Offline checks for official credential routing, endpoint and parameter handling."""
import io
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'agent'))
import bailian_client as shared
import deepseek_client as official


class AdapterChecks(unittest.TestCase):
    def setUp(self):
        self.config = shared.load_config()
        self.assertEqual(self.config['provider'],'deepseek_official')

    def test_active_credential_uses_new_env(self):
        with patch.dict(shared.os.environ,{'DASHSCOPE_API_KEY':'OLD_PROVIDER_SENTINEL',
            'DEEPSEEK_API_KEY':'OFFICIAL_SENTINEL'},clear=True):
            self.assertEqual(shared.read_api_key(),'OFFICIAL_SENTINEL')

    def test_missing_official_key_never_falls_back(self):
        with patch.object(official,'read_api_key',return_value='') as credential, \
             patch.object(official.urllib.request,'build_opener') as network:
            with self.assertRaisesRegex(shared.ClientError,'MISSING_DEEPSEEK_API_KEY'):
                shared.chat_completion(self.config,[{'role':'user','content':'probe'}])
            credential.assert_called_once_with('DEEPSEEK_API_KEY')
            network.assert_not_called()

    def test_wrong_endpoint_rejected_before_credential_access(self):
        config = {**self.config,'base_url':'https://example.invalid'}
        with patch.object(official,'read_api_key') as credential:
            with self.assertRaisesRegex(shared.ClientError,'UNAPPROVED_DEEPSEEK'):
                official.chat_completion(config,[])
            credential.assert_not_called()

    def test_request_uses_official_parameter_and_six_tools(self):
        raw = {'model':'deepseek-flash','choices':[{'message':{'content':'READY'}}]}
        class Reply(io.BytesIO):
            def __enter__(self): return self
            def __exit__(self,*args): self.close()
        observed=[]
        class Opener:
            def open(self,request,timeout):
                observed.append((request,timeout)); return Reply(json.dumps(raw).encode())
        with patch.object(official,'read_api_key',return_value='OFFICIAL_SENTINEL'), \
             patch.object(official.urllib.request,'build_opener',return_value=Opener()):
            payload,result=shared.chat_completion(self.config,[{'role':'user','content':'probe'}],
                tools=shared.load_tools(),tool_choice='auto',max_tokens=256)
        self.assertEqual(observed[0][0].full_url,'https://api.deepseek.com/chat/completions')
        self.assertEqual(observed[0][0].get_header('Authorization'),'Bearer OFFICIAL_SENTINEL')
        self.assertEqual(payload['thinking'],{'type':'disabled'})
        self.assertNotIn('enable_thinking',payload)
        self.assertEqual(len(payload['tools']),6)
        self.assertEqual(result,raw)

    def test_thinking_not_silently_enabled_without_replay_support(self):
        config={**self.config,'generation_settings':{**self.config['generation_settings'],'enable_thinking':True}}
        with self.assertRaisesRegex(shared.ClientError,'THINKING_TOOL_REPLAY_NOT_CONFIGURED'):
            official.validate_config(config)

    def test_http_errors_never_echo_provider_body_or_retry(self):
        from urllib.error import HTTPError
        error=HTTPError('https://api.deepseek.com/chat/completions',401,'credential echo',{},io.BytesIO(b'OFFICIAL_SENTINEL'))
        class Opener:
            calls=0
            def open(self,*args,**kwargs):
                self.calls+=1; raise error
        opener=Opener()
        with patch.object(official,'read_api_key',return_value='OFFICIAL_SENTINEL'), \
             patch.object(official.urllib.request,'build_opener',return_value=opener):
            with self.assertRaises(shared.ClientError) as caught:
                official.chat_completion(self.config,[])
        self.assertEqual(str(caught.exception),'DEEPSEEK_HTTP_401')
        self.assertEqual(caught.exception.details,{'http_status':401})
        self.assertEqual(opener.calls,1)


if __name__ == '__main__':
    unittest.main()
