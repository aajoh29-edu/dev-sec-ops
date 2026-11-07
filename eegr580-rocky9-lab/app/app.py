"""EEGR 580 demo service — stdlib only, safe baseline (what lives on main)."""
import ast
import ipaddress
import json
import operator
import re
import socket
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

HOST_RE = re.compile(r"^(?=.{1,253}$)([a-zA-Z0-9-]{1,63}\.)*[a-zA-Z0-9-]{1,63}$")
OPS = {ast.Add: operator.add, ast.Sub: operator.sub, ast.Mult: operator.mul, ast.Div: operator.truediv}
SECURITY_HEADERS = {
    "Content-Security-Policy": "default-src 'none'; frame-ancestors 'none'",
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
    "Referrer-Policy": "no-referrer",
    "Permissions-Policy": "()",
    "Cross-Origin-Resource-Policy": "same-origin",
    "Cache-Control": "no-store",
}


def safe_calc(expr: str) -> float:
    """Arithmetic only: numbers and + - * /. Anything else is rejected."""
    def ev(node):
        if isinstance(node, ast.Expression):
            return ev(node.body)
        if isinstance(node, ast.Constant) and isinstance(node.value, (int, float)):
            return node.value
        if isinstance(node, ast.BinOp) and type(node.op) in OPS:
            return OPS[type(node.op)](ev(node.left), ev(node.right))
        raise ValueError("unsupported expression")
    return ev(ast.parse(expr, mode="eval"))


def lookup(host: str) -> str:
    try:
        return str(ipaddress.ip_address(host))
    except ValueError:
        if not HOST_RE.match(host):
            raise ValueError("invalid host")
        return socket.gethostbyname(host)


class Handler(BaseHTTPRequestHandler):
    server_version = "app"
    sys_version = ""

    def _send(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        for k, v in SECURITY_HEADERS.items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        url = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(url.query).items()}
        try:
            if url.path in ("/", "/health"):
                return self._send(200, {"status": "ok"})
            if url.path == "/api/lookup":
                return self._send(200, {"address": lookup(q.get("host", ""))})
            if url.path == "/api/calc":
                return self._send(200, {"result": safe_calc(q.get("expr", ""))})
            return self._send(404, {"error": "not found"})
        except (ValueError, OSError, SyntaxError, ZeroDivisionError):
            return self._send(400, {"error": "bad request"})

    def log_message(self, fmt, *args):
        print("%s %s" % (self.address_string(), fmt % args), flush=True)


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8000), Handler).serve_forever()
