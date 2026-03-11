"""Long-lived MCP client singleton for the Jac GPT server.

Spawns `jac mcp --transport stdio` as a subprocess using the same
newline-delimited JSON-RPC protocol as list_mcp_sse.jac and keeps the
subprocess alive for the lifetime of the Jac server process.

Two functions defined at the bottom (list_available_mcp_tools and
call_mcp_tool) are imported by jacServer.jac and passed as ReAct tools
to LLM nodes, giving the LLM the choice between RAG and MCP on every turn.
"""

import json;
import subprocess;
import threading;
import os;

obj McpClient {
    has proc: any = None;
    has _tools: list = [];
    has _initialized: bool = False;
    has _rpc_id: int = 0;

    def postinit() {
        try {
            self._launch();
            self._initialize();
            self._list_tools();
            print(f"[MCP] Client ready — {len(self._tools)} tool(s) discovered.");
        } except Exception as e {
            print(f"[MCP] Startup warning: {e}. MCP tools will be unavailable.");
            self.proc = None;
        }
    }

    # ── Private helpers ────────────────────────────────────────────────────────

    def _make_id() -> str {
        self._rpc_id += 1;
        return str(self._rpc_id);
    }

    def _launch() {
        # Server is always started from the project root (where jac.toml lives)
        project_dir = os.getcwd();
        self.proc = subprocess.Popen(
            ["jac", "mcp", "--transport", "stdio"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            cwd=project_dir
        );

        # Drain stderr in a daemon thread to prevent pipe deadlock
        def _drain(stream: any) -> None {
            try {
                for line in stream {
                    
                }
            } except Exception {
                raise;
            }
        }
        t = threading.Thread(target=_drain, args=[self.proc.stderr], daemon=True);
        t.start();
    }

    def _send_rpc(method: str, params: dict = None) -> dict {
        req = {"jsonrpc": "2.0", "id": self._make_id(), "method": method};
        if params {
            req["params"] = params;
        }
        self.proc.stdin.write(json.dumps(req) + "\n");
        self.proc.stdin.flush();
        response_line = self.proc.stdout.readline();
        if not response_line {
            raise Exception(f"MCP server closed stdout waiting for '{method}'");
        }
        return json.loads(response_line.strip());
    }

    def _send_notification(method: str, params: dict = None) -> None {
        body = {"jsonrpc": "2.0", "method": method};
        if params {
            body["params"] = params;
        }
        self.proc.stdin.write(json.dumps(body) + "\n");
        self.proc.stdin.flush();
    }

    def _initialize() {
        self._send_rpc("initialize", {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "jac-mcp-server-bridge", "version": "1.0.0"}
        });
        # Fire-and-forget — no response expected
        self._send_notification("notifications/initialized");
        self._initialized = True;
    }

    def _list_tools() {
        resp = self._send_rpc("tools/list");
        self._tools = resp.get("result", {}).get("tools", []);
    }

    # ── Public API ─────────────────────────────────────────────────────────────

    """Return a human-readable list of all available MCP tools with their
    descriptions and parameter names so the LLM can decide which to call."""
    def get_tool_descriptions() -> str {
        if not self._tools {
            return "No MCP tools are currently available.";
        }
        lines = [];
        for tool in self._tools {
            name = tool.get("name", "unknown");
            desc = tool.get("description", "");
            props = list(tool.get("inputSchema", {}).get("properties", {}).keys());
            lines.append(f"- {name}: {desc} (params: {props})");
        }
        return "\n".join(lines);
    }

    """Call an MCP tool by name with the given arguments dict.
    Returns the tool's text output as a string, or an error description."""
    def call_tool(name: str, args: dict) -> str {
        if not self.proc or not self._initialized {
            return "MCP client is not available — use search_docs instead.";
        }
        try {
            resp = self._send_rpc("tools/call", {"name": name, "arguments": args});
            content = resp.get("result", {}).get("content", []);
            if content {
                parts = [];
                for item in content {
                    if item.get("type") == "text" {
                        parts.append(item.get("text", ""));
                    } else {
                        parts.append(str(item));
                    }
                }
                return "\n".join(parts);
            }
            error = resp.get("error");
            if error {
                return f"MCP tool error: {error}";
            }
            return "MCP tool returned no content.";
        } except Exception as e {
            return f"MCP call failed: {e}";
        }
    }

    """Shut down the MCP server subprocess cleanly."""
    def close() {
        if self.proc {
            try {
                self.proc.stdin.close();
            } except Exception {
                
            }
            try {
                self.proc.wait(timeout=5);
            } except Exception {
                self.proc.kill();
            }
        }
    }
}
