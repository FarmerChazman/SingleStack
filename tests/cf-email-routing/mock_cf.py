"""Minimal in-memory mock of the Cloudflare Email Routing API for testing cf-email-routing.sh."""
import json, re, sys, uuid
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs

TOKEN = "test-token"
ACCOUNT = "acct1"
zones = {
    "z1": {"name": "example.com", "er": {"enabled": True, "status": "ready", "support_subaddress": False},
           "dns": [{"type": "MX", "name": "example.com", "content": "route1.mx.cloudflare.net", "priority": 13},
                   {"type": "TXT", "name": "example.com", "content": "\"v=spf1 include:spf.brevo.com ~all\""}],
           "rules": [{"id": "r1", "enabled": True, "matchers": [{"type": "literal", "field": "to", "value": "support@example.com"}],
                      "actions": [{"type": "forward", "value": ["old@x.example"]}]},
                     {"id": "r2", "enabled": True, "matchers": [{"type": "literal", "field": "to", "value": "legacy@example.com"}],
                      "actions": [{"type": "forward", "value": ["you@your-mailbox.example"]}]}],
           "catch_all": {"enabled": False, "matchers": [{"type": "all"}], "actions": [{"type": "drop"}]}},
    "z2": {"name": "example.org", "er": {"enabled": False, "status": "unconfigured", "support_subaddress": False},
           "dns": [], "rules": [], "catch_all": {"enabled": False, "matchers": [{"type": "all"}], "actions": [{"type": "drop"}]}},
    "z3": {"name": "example.net", "er": {"enabled": False, "status": "unconfigured", "support_subaddress": False},
           "dns": [{"type": "MX", "name": "example.net", "content": "aspmx.l.google.com", "priority": 1}],
           "rules": [], "catch_all": {"enabled": False, "matchers": [{"type": "all"}], "actions": [{"type": "drop"}]}},
}
addresses = [{"email": "you@your-mailbox.example", "verified": None}]
calls = []

def page(items, q):
    per = int(q.get("per_page", ["20"])[0]); p = int(q.get("page", ["1"])[0])
    total_pages = max(1, -(-len(items) // per))
    return items[(p - 1) * per: p * per], {"page": p, "per_page": per, "total_pages": total_pages, "count": len(items)}

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, code, result=None, info=None, errors=None):
        body = {"success": errors is None, "errors": errors or [], "messages": [], "result": result}
        if info: body["result_info"] = info
        b = json.dumps(body).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"{}")
    def route(self, method):
        if self.headers.get("Authorization") != f"Bearer {TOKEN}":
            return self.send(403, errors=[{"code": 10000, "message": "Authentication error"}])
        u = urlparse(self.path); q = parse_qs(u.query); p = u.path.replace("/client/v4", "")
        calls.append(f"{method} {p}")
        if p == "/zones" and method == "GET":
            name = q.get("name", [""])[0]
            return self.send(200, [{"id": k, "name": z["name"]} for k, z in zones.items() if z["name"] == name])
        if m := re.fullmatch(r"/accounts/(\w+)/email/routing/addresses", p):
            if method == "GET":
                items, info = page(addresses, q); return self.send(200, items, info)
            a = {"email": self.body()["email"], "verified": None}; addresses.append(a); return self.send(200, a)
        m = re.fullmatch(r"/zones/(\w+)(/.*)", p)
        if not m or m.group(1) not in zones: return self.send(404, errors=[{"code": 7003, "message": "no route"}])
        z = zones[m.group(1)]; rest = m.group(2)
        if rest == "/email/routing":
            if method == "PATCH": z["er"].update({k: v for k, v in self.body().items() if k == "support_subaddress"})
            return self.send(200, dict(z["er"], name=z["name"]))
        if rest == "/email/routing/dns":
            if method == "POST":
                if any(r["type"] == "MX" and "cloudflare" not in r["content"] for r in z["dns"]):
                    return self.send(400, errors=[{"code": 2008, "message": "Non-Cloudflare MX records exist"}])
                z["er"].update(enabled=True, status="ready")
                for i in (1, 2, 3): z["dns"].append({"type": "MX", "name": z["name"], "content": f"route{i}.mx.cloudflare.net", "priority": i})
                if not any("v=spf1" in r["content"] for r in z["dns"] if r["type"] == "TXT"):
                    z["dns"].append({"type": "TXT", "name": z["name"], "content": "v=spf1 include:_spf.mx.cloudflare.net ~all"})
                return self.send(200, dict(z["er"], name=z["name"]))
            return self.send(200, {"record": [{"type": "MX", "name": z["name"], "content": "route1.mx.cloudflare.net", "priority": 13}]})
        if rest == "/dns_records":
            items = [r for r in z["dns"] if r["type"] == q.get("type", [r["type"]])[0] and r["name"] == q.get("name", [r["name"]])[0]]
            items, info = page(items, q); return self.send(200, items, info)
        if rest == "/email/routing/rules/catch_all":
            if method == "PUT": z["catch_all"] = self.body()
            return self.send(200, z["catch_all"])
        if rest == "/email/routing/rules":
            if method == "POST":
                r = self.body(); r["id"] = uuid.uuid4().hex; z["rules"].append(r); return self.send(200, r)
            items, info = page(z["rules"], q); return self.send(200, items, info)
        if m2 := re.fullmatch(r"/email/routing/rules/(\w+)", rest):
            for i, r in enumerate(z["rules"]):
                if r["id"] == m2.group(1):
                    new = self.body(); new["id"] = r["id"]; z["rules"][i] = new; return self.send(200, new)
            return self.send(404, errors=[{"code": 1, "message": "rule not found"}])
        return self.send(404, errors=[{"code": 7003, "message": f"unhandled {method} {rest}"}])
    def do_GET(self): self.route("GET")
    def do_POST(self): self.route("POST")
    def do_PUT(self): self.route("PUT")
    def do_PATCH(self): self.route("PATCH")

if __name__ == "__main__":
    HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
