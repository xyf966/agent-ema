"""Own one MATLAB batch worker. LLM text is JSON data, never command text."""

import json
import os
from pathlib import Path
import subprocess
import shutil
import time
import uuid

from bailian_client import ROOT, read_json


class BridgeError(Exception):
    pass


class MatlabBridge:
    def __init__(self, log_folder, matlab_exe=None, *, profile="stage3"):
        if profile not in {"stage3", "stage4"}:
            raise BridgeError("UNAPPROVED_TOOL_PROFILE")
        self.profile = profile
        self.log_folder = Path(log_folder).resolve()
        self.log_folder.relative_to(ROOT / "results")
        self.log_folder.mkdir(parents=True, exist_ok=True)
        self.job_id = "JOB-" + uuid.uuid4().hex
        self.folder = ROOT / "work/agent_bridge" / self.job_id
        self.folder.mkdir(parents=True)
        self.sequence = 0
        self.process = None
        self.output = None
        self.matlab_exe = Path(matlab_exe or os.environ.get("EMA_MATLAB_EXE", "C:/Program Files/MATLAB/R2025a/bin/matlab.exe"))
        self.runtime = None

    def start(self, timeout_s=90):
        if not self.matlab_exe.is_file():
            raise BridgeError("MATLAB_EXECUTABLE_NOT_FOUND")
        # Command components come exclusively from this repository and random ID.
        code = "addpath('" + (ROOT / "agent/matlab").as_posix().replace("'", "''") + "');ema_agent_worker('" + self.job_id + "','" + self.profile + "')"
        env = os.environ.copy()
        env.pop("DASHSCOPE_API_KEY", None)
        env.pop("DEEPSEEK_API_KEY", None)
        self.output = (self.log_folder / "matlab_worker.log").open("wb")
        self.process = subprocess.Popen([str(self.matlab_exe), "-sd", str(ROOT), "-batch", code],
            cwd=ROOT, env=env, stdout=self.output, stderr=subprocess.STDOUT,
            creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
        self.runtime = self._wait_json(self.folder / "ready.json", timeout_s)
        expected = "ema_tool_stage4" if self.profile == "stage4" else "ema_tool"
        if self.runtime.get("tool_profile") != self.profile or self.runtime.get("dispatcher") != expected:
            raise BridgeError("MATLAB_WORKER_PROFILE_MISMATCH")
        return self.runtime

    def _wait_json(self, path, timeout_s):
        until = time.monotonic() + timeout_s
        while time.monotonic() < until:
            if path.is_file():
                return read_json(path)
            if self.process.poll() is not None:
                raise BridgeError("MATLAB_WORKER_EXITED")
            time.sleep(0.1)
        raise BridgeError("MATLAB_WORKER_TIMEOUT")

    def call(self, tool, arguments, timeout_s=45):
        if self.runtime is None:
            raise BridgeError("MATLAB_WORKER_NOT_STARTED")
        self.sequence += 1
        name = f"request_{self.sequence:04d}.json"
        temporary = self.folder / (name + ".tmp")
        temporary.write_text(json.dumps({"sequence": self.sequence, "tool": tool, "arguments": arguments},
            ensure_ascii=False, allow_nan=False), encoding="utf-8")
        temporary.replace(self.folder / name)
        envelope = self._wait_json(self.folder / f"response_{self.sequence:04d}.json", timeout_s)
        if envelope.get("sequence") != self.sequence or envelope.get("bridge_status") != "ok":
            raise BridgeError("MATLAB_WORKER_ENVELOPE_INVALID")
        return envelope["response"]

    def close(self):
        (self.folder / "stop").touch()
        if self.process is not None:
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.terminate()
                try:
                    self.process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait(timeout=5)
        if self.output is not None:
            self.output.close()
        # Preserve protocol evidence outside the disposable work/cache tree.
        archive = self.log_folder / "worker_records"
        archive.mkdir(exist_ok=True)
        for pattern in ("ready.json", "stopped.json", "request_*.json", "response_*.json"):
            for path in self.folder.glob(pattern):
                if path.is_file():
                    shutil.copyfile(path, archive / path.name)
