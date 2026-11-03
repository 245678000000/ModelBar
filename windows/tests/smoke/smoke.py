#!/usr/bin/env python3
"""真实程序端到端测试：用一个只支持 Chat 的模拟接口，跑真实的 Agent。

用法：python smoke.py <DevCli 路径> <ModelBarGateway 路径> [工具名...]
只操作临时目录，不碰真实配置。任何工具失败时退出码非 0。
"""
import http.server
import json
import os
import pathlib
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
import uuid

ANSWER = "MODELBAR_MOCK_OK"
TOOL_ANSWER = "TOOL_RESULT_SEEN"
MARKER = "bridge-tool-ok"
log = []
lock = threading.Lock()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def send_json(self, value, code=200):
        raw = json.dumps(value).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def authorized(self):
        if self.headers.get("Authorization") == "Bearer sk-smoke-upstream":
            return True
        self.send_json({"error": {"message": "bad key"}}, 401)
        return False

    def do_GET(self):
        if not self.authorized():
            return
        if self.path.rstrip("/").endswith("/models"):
            return self.send_json({"object": "list", "data": [{"id": "test-model", "context_length": 128000, "supports_reasoning": True}]})
        self.send_json({"error": {"message": "not found"}}, 404)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(length) or b"{}")
        if not self.authorized():
            return
        if self.path.split("?")[0].endswith("/chat/completions"):
            with lock:
                log.append(body)
            return self.chat(body)
        self.send_json({"error": {"message": "not found"}}, 404)

    def chat(self, body):
        model = body.get("model", "test-model")
        if str(model).startswith("grok-"):
            return self.send_json({"error": {"message": "model not found"}}, 404)
        text = json.dumps(body.get("messages", []))
        wants_tool = body.get("tools") and body.get("stream") and "RUN_TOOL" in text
        has_result = any(m.get("role") == "tool" for m in body.get("messages", []))
        if not body.get("stream"):
            return self.send_json({
                "id": "c", "object": "chat.completion", "created": 1, "model": model,
                "choices": [{"index": 0, "finish_reason": "stop", "message": {"role": "assistant", "content": ANSWER}}],
                "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
            })
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.close_connection = True
        self.end_headers()

        def chunk(delta, finish=None):
            payload = {"id": "c", "object": "chat.completion.chunk", "created": 1, "model": model,
                       "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
            self.wfile.write(f"data: {json.dumps(payload)}\n\n".encode())
            self.wfile.flush()

        if wants_tool and not has_result:
            tools = {t["function"]["name"]: t["function"].get("parameters", {}).get("properties", {}) for t in body["tools"]}
            preferred = ("exec_command", "Bash", "bash", "Execute", "execute", "run_terminal_command", "shell")
            name = next((n for n in preferred if n in tools), next(iter(tools)))
            prop = next((k for k in ("cmd", "command", "commands") if k in tools.get(name, {})), "command")
            arguments = {prop: f"echo {MARKER}"}
            for key in ("description", "riskLevelReason"):
                if key in tools.get(name, {}):
                    arguments[key] = "print marker"
            if "riskLevel" in tools.get(name, {}):
                arguments["riskLevel"] = "low"
            encoded = json.dumps(arguments)
            chunk({"role": "assistant", "reasoning_content": "thinking"})
            chunk({"tool_calls": [{"index": 0, "id": "call_abc", "type": "function", "function": {"name": name, "arguments": ""}}]})
            chunk({"tool_calls": [{"index": 0, "function": {"arguments": encoded}}]})
            chunk({}, "tool_calls")
        elif wants_tool:
            result = [m for m in body["messages"] if m.get("role") == "tool"][-1]
            seen = MARKER in str(result.get("content"))
            chunk({"role": "assistant", "content": TOOL_ANSWER if seen else "TOOL_RESULT_MISSING"})
            chunk({}, "stop")
        else:
            chunk({"role": "assistant", "content": ANSWER})
            chunk({}, "stop")
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()


class QuietServer(http.server.ThreadingHTTPServer):
    def handle_error(self, request, client_address):
        # 客户端用完连接直接断开很常见，不是错误。
        if not isinstance(sys.exc_info()[1], ConnectionError):
            super().handle_error(request, client_address)


def kill_tree(process):
    if os.name == "nt":
        subprocess.run(["taskkill", "/T", "/F", "/PID", str(process.pid)], capture_output=True)
    else:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except OSError:
            pass


def run(command, env=None, timeout=150, cwd=None):
    """输出写文件而不是管道：后台服务继承了管道句柄时，读管道会一直等下去，超时也没用。"""
    with tempfile.TemporaryFile() as output:
        options = {} if os.name == "nt" else {"start_new_session": True}
        try:
            process = subprocess.Popen(command, env=env, cwd=cwd, stdin=subprocess.DEVNULL, stdout=output,
                                       stderr=subprocess.STDOUT, shell=False, **options)
        except OSError as error:
            return -2, str(error)
        try:
            code = process.wait(timeout)
        except subprocess.TimeoutExpired:
            kill_tree(process)
            code = -1
        output.seek(0)
        text = output.read().decode("utf-8", "replace")
        return code, f"[timeout after {timeout}s]\n{text}" if code == -1 else text


def which(name):
    return shutil.which(name)


def main():
    # Windows 控制台默认不是 UTF-8，打印中文会报错。
    sys.stdout.reconfigure(encoding="utf-8", errors="replace", line_buffering=True)
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    cli, gateway = sys.argv[1], str(pathlib.Path(sys.argv[2]).resolve())
    wanted = sys.argv[3:] or ["ClaudeCode", "Codex", "OpenCode", "Pi"]
    home = pathlib.Path(tempfile.mkdtemp(prefix="modelbar smoke "))
    work = home / "work"
    work.mkdir()

    server = QuietServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_address[1]}/v1"

    environ = dict(os.environ, MODELBAR_SANDBOX_USE_PATH="1")
    for name in ("OPENAI_API_KEY", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT"):
        environ.pop(name, None)
    # 嵌套运行时父进程可能带着 Claude 的变量。
    for name in list(environ):
        if name.startswith(("ANTHROPIC_", "CLAUDE_")):
            environ.pop(name)

    def devcli(*args):
        code, output = run([cli, str(home), gateway, *args], environ, timeout=120)
        if code != 0:
            print(output)
            raise SystemExit(f"devcli {args} failed with {code}")
        return output

    tool_env = dict(environ,
                    CODEX_HOME=str(home / ".codex"),
                    XDG_CONFIG_HOME=str(home / ".config"),
                    XDG_DATA_HOME=str(home / ".local" / "share"),
                    XDG_STATE_HOME=str(home / ".local" / "state"),
                    XDG_CACHE_HOME=str(home / ".cache"),
                    CLAUDE_CONFIG_DIR=str(home / ".claude"),
                    PI_CODING_AGENT_DIR=str(home / ".pi" / "agent"),
                    GROK_HOME=str(home / ".grok"),
                    DISABLE_TELEMETRY="1",
                    DISABLE_ERROR_REPORTING="1")

    def path_of(name):
        return shutil.which(name, path=environ.get("PATH")) or name

    commands = {
        "ClaudeCode": lambda prompt, tool: [path_of("claude"), "-p", prompt, *(["--allowedTools", "Bash"] if tool else [])],
        "Codex": lambda prompt, tool: [path_of("codex"), "exec", "--skip-git-repo-check", "--ephemeral", "--sandbox", "read-only", prompt],
        "OpenCode": lambda prompt, tool: [path_of("opencode"), "run", "--standalone", *(["--auto"] if tool else []), prompt],
        "Pi": lambda prompt, tool: [path_of("pi"), "-p", prompt],
        "Grok": lambda prompt, tool: [path_of("grok"), "-p", prompt, *(["--always-approve"] if tool else [])],
    }

    print(devcli("add", "smoke", base + "/", "sk-smoke-upstream"))
    devcli("effort", "High")
    for tool in wanted:
        devcli("tool", tool, "on")
    print(devcli("bridge", "on"))

    support = pathlib.Path(json.loads((home / "AppData" / "Roaming" / "ModelBar" / "bridge.json").read_text(encoding="utf-8"))["tokenFile"]).parent.parent
    installed = support / "bin" / ("ModelBarGateway.exe" if os.name == "nt" else "ModelBarGateway")
    code, printed = run([str(installed), "--print-file", str(support / "keys" / "bridge.token")])
    failures = []
    check = lambda name, ok, detail="": (print(f"{'PASS' if ok else 'FAIL'}  {name} {detail}"), ok or failures.append(name))
    check("helper prints the token file", code == 0 and printed.startswith("mb-") and not printed.endswith("\n"))

    port = json.loads((support / "bridge.json").read_text(encoding="utf-8"))["port"]
    health = lambda: json.loads(urllib.request.build_opener(urllib.request.ProxyHandler({})).open(f"http://127.0.0.1:{port}/health", timeout=2).read())
    check("service is healthy", health().get("ok") is True)

    for tool in wanted:
        with lock:
            log.clear()
        print(f"--- {tool}")
        code, output = run(commands[tool]("say hi", False), tool_env, timeout=90, cwd=str(work))
        with lock:
            requests = len(log)
        check(f"{tool} chat", ANSWER in output, f"exit={code} requests={requests}" + ("" if ANSWER in output else f"\n{output[-1500:]}"))

        with lock:
            log.clear()
        code, output = run(commands[tool]("RUN_TOOL please run the command", True), tool_env, timeout=90, cwd=str(work))
        with lock:
            returned = any(MARKER in str(m.get("content")) for body in log for m in body.get("messages", []) if m.get("role") == "tool")
        check(f"{tool} tool call", TOOL_ANSWER in output and returned, f"exit={code}" + ("" if TOOL_ANSWER in output else f"\n{output[-1500:]}"))

    # 守护进程：杀掉服务后应该自动恢复。
    pid = int((support / "bridge.pid").read_text())
    if os.name == "nt":
        children = run(["powershell", "-NoProfile", "-Command", f"(Get-CimInstance Win32_Process -Filter 'ParentProcessId={pid}').ProcessId"])[1].split()
        for child in children:
            run(["taskkill", "/F", "/PID", child])
    else:
        children = run(["pgrep", "-P", str(pid)])[1].split()
        for child in children:
            run(["kill", "-9", child])
    recovered = False
    for _ in range(40):
        time.sleep(0.5)
        try:
            recovered = health().get("ok") is True
            if recovered:
                break
        except OSError:
            pass
    check("service recovers after being killed", bool(children) and recovered)

    # 关闭后应该清理干净。
    for tool in wanted:
        devcli("tool", tool, "off")
    state = json.loads((support / "state.json").read_text(encoding="utf-8"))
    check("originals cleared", not state["originals"])
    check("no key files left", not [p for p in (support / "keys").iterdir() if p.suffix in (".key", ".token")])
    check("service stopped", not (support / "bridge.pid").exists())
    time.sleep(1)
    try:
        health()
        check("port released", False)
    except OSError:
        check("port released", True)

    server.shutdown()
    print(f"\n{len(failures)} failed" if failures else "\nall passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
