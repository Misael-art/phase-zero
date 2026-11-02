"""Pinned Harness Account RPC adapter. OAuth/PKCE stays owned by upstream.

Launch token, cookie and authorization URL remain in supervisor memory. Only
the two account methods below are exposed; this is not a general RPC bridge.
"""
import http.cookiejar
import json
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from datetime import datetime


class AccountBridgeError(RuntimeError):
    pass


class _LocalRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if urllib.parse.urlsplit(newurl).netloc != urllib.parse.urlsplit(req.full_url).netloc:
            raise AccountBridgeError("Unexpected authentication redirect")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


class AccountSession:
    def __init__(self, launch_url: str, port: int, *, version: str):
        url = urllib.parse.urlsplit(launch_url)
        if url.scheme != "http" or url.hostname not in {"127.0.0.1", "localhost"} or url.port != port or url.username or url.password:
            raise AccountBridgeError("Invalid local Harness authority")
        self.origin = f"http://127.0.0.1:{port}"
        self.version = version
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}),
            urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()), _LocalRedirect())
        try:
            with self.opener.open(launch_url, timeout=1) as response:
                if response.status != 200:
                    raise AccountBridgeError("Local authentication failed")
        except Exception:
            raise AccountBridgeError("Could not authenticate with local Harness") from None

    def call(self, method, args):
        if method not in {"account/getState", "account/startSignIn"}:
            raise AccountBridgeError("Unsupported account operation")
        rpc_id = str(uuid.uuid4())
        body = json.dumps({"type": "client-request", "rpcId": rpc_id, "method": method, "payload": {"args": args}}).encode()
        request = urllib.request.Request(self.origin + "/api/" + method, data=body,
            headers={"Content-Type": "application/json", "Origin": self.origin}, method="POST")
        try:
            with self.opener.open(request, timeout=1) as response:
                raw = response.read(65537)
            if len(raw) > 65536:
                raise ValueError
            value = json.loads(raw)
            if value.get("rpcId") != rpc_id or value.get("result", {}).get("ok") is not True:
                raise ValueError
            result = value["result"]["value"]
            if not isinstance(result, dict): raise ValueError
            return result
        except Exception:
            raise AccountBridgeError("Harness account operation unavailable; open Account settings to retry") from None

    def state(self):
        value = self.call("account/getState", {})
        attempt = value.get("attempt") or {}
        return {"state": value.get("status") if value.get("status") in {"credential-stored", "signed-out"} else "unknown",
                "phase": attempt.get("phase") if attempt.get("phase") in {
                    "initializing", "waiting-browser", "exchanging", "committing", "succeeded", "cancelled", "expired", "failed"} else "unknown"}

    def login_url(self):
        value = self.call("account/startSignIn", {"client": {"version": self.version, "locale": "en-US",
                             "timezoneOffsetSeconds": -int(datetime.now().astimezone().utcoffset().total_seconds())},
                             "callbackOrigin": self.origin, "loginSource": "web"})
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            attempt = value.get("attempt") or {}
            raw = attempt.get("authorizeUrl")
            if raw:
                url = urllib.parse.urlsplit(raw)
                if (url.scheme == "https" and url.hostname == "platform.deepseek.com" and
                    url.path == "/dsh/authorize" and url.port in {None, 443} and not url.username and not url.password and not url.fragment):
                    return raw
                raise AccountBridgeError("Unexpected DeepSeek authorization authority")
            if attempt.get("phase") in {"failed", "cancelled", "expired"}:
                raise AccountBridgeError("DeepSeek authorization unavailable; retry in Harness Account settings")
            time.sleep(0.2)
            value = self.call("account/getState", {})
        raise AccountBridgeError("DeepSeek authorization timed out; retry in Harness Account settings")
