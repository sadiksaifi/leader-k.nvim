# A fake OpenAI-compatible Chat Completions server for the tests.
#
# Model "script" replays /tmp/leader-k-test-script.json, a list of replies.
# The reply sent is the one at the index equal to the number of assistant
# messages in the request. A reply is an object with optional fields:
#   content: text, streamed in pieces of `piece` characters
#   tool_calls: [{"name": ..., "arguments": object or string}]
#   finish: the finish_reason, "tool_calls" or "stop" by default
#   delay: seconds between pieces
#   reasoning: send reasoning chunks first
#   hang: after the content, keep the stream open
# Other model names select fixed error behaviors.
import json, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG = '/tmp/leader-k-test-request.json'
SCRIPT = '/tmp/leader-k-test-script.json'

def chunk(delta=None, finish=None, error=None):
    d = {"id": "gen-1", "object": "chat.completion.chunk",
         "choices": [{"index": 0, "delta": delta or {}, "finish_reason": finish}]}
    if error: d["error"] = error
    return ("data: " + json.dumps(d) + "\n\n").encode()

class H(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *a): pass

    def plain(self, status, obj):
        data = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        auth = self.headers.get('Authorization')
        # Every request is kept, so tests can check the whole loop.
        try:
            log = json.load(open(LOG))
        except Exception:
            log = []
        log.append({"body": body, "auth_present": bool(auth), "auth_prefix": (auth or '')[:7]})
        json.dump(log, open(LOG, 'w'), indent=1)
        model = body.get('model', '')
        if model == 'err401':
            return self.plain(401, {"error": {"message": "User not found.", "code": 401}})
        if model == 'err402':
            return self.plain(402, {"error": {"message": "Insufficient credits", "code": 402}})
        if model == 'notools':
            return self.plain(404, {"error": {"message": "No endpoints found that support tool use.", "code": 404}})
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Connection', 'close')
        self.end_headers()
        w = self.wfile
        def send(b):
            w.write(b); w.flush()
        try:
            if model == 'hang':
                send(b": OPENROUTER PROCESSING\n\n")
                time.sleep(30); return
            if model == 'midstream':
                send(chunk({"content": "Let me "})); time.sleep(0.2)
                send(chunk(finish="error", error={"code": "server_error", "message": "Provider disconnected unexpectedly"})); return
            if model == 'cut':
                send(chunk({"content": "Partial"})); time.sleep(0.2); return
            if model == 'crlf':
                w.write(b'data: {"choices":[{"delta":{"content":"Hi there"}}]}\r\n\r\n')
                w.write(b'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\r\n\r\ndata: [DONE]\r\n\r\n'); w.flush(); return
            if model == 'nodone':
                send(chunk({"content": "Done"})); send(chunk(finish="stop")); return
            script = json.load(open(SCRIPT))
            n = sum(1 for m in body['messages'] if m.get('role') == 'assistant')
            r = script[min(n, len(script) - 1)]
            delay = r.get('delay', 0)
            piece = r.get('piece', 5)
            if r.get('reasoning'):
                for _ in range(4):
                    send(chunk({"reasoning": "hmm "})); time.sleep(delay)
            text = r.get('content', '')
            for i in range(0, len(text), piece):
                send(chunk({"content": text[i:i + piece]})); time.sleep(delay)
            calls = r.get('tool_calls', [])
            for i, c in enumerate(calls):
                args = c.get('arguments', {})
                if not isinstance(args, str):
                    args = json.dumps(args)
                send(chunk({"tool_calls": [{"index": i, "id": "call_%d_%d" % (n, i), "type": "function",
                                            "function": {"name": c['name'], "arguments": ""}}]}))
                for j in range(0, len(args), 7):
                    send(chunk({"tool_calls": [{"index": i, "function": {"arguments": args[j:j + 7]}}]}))
                    time.sleep(delay)
            if r.get('hang'):
                time.sleep(30); return
            send(chunk(finish=r.get('finish', 'tool_calls' if calls else 'stop')))
            send(b"data: [DONE]\n\n")
        except BrokenPipeError:
            pass

ThreadingHTTPServer(('127.0.0.1', 8765), H).serve_forever()
