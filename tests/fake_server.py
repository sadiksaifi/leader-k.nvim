import json, time, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG = '/tmp/leader-k-test-request.json'

def chunk(content=None, reasoning=None, finish=None, error=None):
    d = {"id": "gen-1", "object": "chat.completion.chunk", "choices": [{"index": 0, "delta": {}, "finish_reason": finish}]}
    if content is not None: d["choices"][0]["delta"]["content"] = content
    if reasoning is not None: d["choices"][0]["delta"]["reasoning"] = reasoning
    if error: d["error"] = error
    return ("data: " + json.dumps(d) + "\n\n").encode()

SLOW = """<code>
local function total(items)
  local sum = 0
  for _, item in ipairs(items) do
    sum = sum + item.price * item.qty
  end
  return sum
end
</code>"""

ANSWER = """<answer>
It multiplies each `price` by its `qty`.

```lua
local x = price * qty
```
</answer>"""

def stream(send, text, delay=0.0):
    # Split mid-tag and mid-line to exercise buffering.
    for i in range(0, len(text), 7):
        send(chunk(content=text[i:i+7])); time.sleep(delay)
    send(chunk(content="", finish="stop"))
    send(b"data: [DONE]\n\n")

class H(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *a): pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        auth = self.headers.get('Authorization')
        json.dump({"body": body, "auth_present": bool(auth), "auth_prefix": (auth or '')[:7]}, open(LOG, 'w'), indent=1)
        model = body.get('model', '')
        if model == 'err401':
            data = json.dumps({"error": {"message": "User not found.", "code": 401}}).encode()
            self.send_response(401); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data); return
        if model == 'err402':
            data = json.dumps({"error": {"message": "Insufficient credits", "code": 402}}).encode()
            self.send_response(402); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data); return
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
            if model == 'think':
                for _ in range(8):
                    send(chunk(reasoning="hmm ")); time.sleep(0.25)
                model = 'fast'
            if model in ('slow', 'fast'):
                delay = 0.12 if model == 'slow' else 0.0
                text = SLOW
                # Split mid-tag and mid-line to exercise buffering.
                for i in range(0, len(text), 7):
                    send(chunk(content=text[i:i+7])); time.sleep(delay)
                send(chunk(content="", finish="stop"))
                send(b"data: [DONE]\n\n"); return
            if model in ('answer', 'answer_slow'):
                stream(send, ANSWER, 0.05 if model == 'answer_slow' else 0.0); return
            if model == 'answer_length':
                send(chunk(content="<answer>\nThe first half")); send(chunk(content="", finish="length")); send(b"data: [DONE]\n\n"); return
            if model == 'midstream':
                send(chunk(content="<code>\nlocal x = ")); time.sleep(0.2)
                send(chunk(content="", finish="error", error={"code": "server_error", "message": "Provider disconnected unexpectedly"})); return
            if model == 'linger':
                send(chunk(content="<code>\nlocal x = 1\n</code>")); send(chunk(content="", finish="stop")); send(b"data: [DONE]\n\n")
                time.sleep(30); return
            if model == 'linger_error':
                send(chunk(content="<code>\nlocal x = ")); send(chunk(content="", finish="error", error={"message": "boom"}))
                time.sleep(30); return
            if model == 'cut':
                send(chunk(content="<code>\nlocal x = 1\n")); time.sleep(0.2); return
            if model == 'refuse':
                send(chunk(content="<error>That needs changes outside the selection.</error>"))
                send(chunk(content="", finish="stop")); send(b"data: [DONE]\n\n"); return
            if model == 'fence':
                send(chunk(content="Here you go:\n```lua\n  return 42\n```\n"))
                send(chunk(content="", finish="stop")); send(b"data: [DONE]\n\n"); return
            if model == 'length':
                send(chunk(content="<code>\nlocal a = 1\n")); send(chunk(content="", finish="length")); send(b"data: [DONE]\n\n"); return
            if model == 'noindent':
                send(chunk(content="<code>\nif x then\n  return 1\nend\n</code>")); send(chunk(content="", finish="stop")); send(b"data: [DONE]\n\n"); return
            if model == 'empty':
                send(chunk(content="<code></code>")); send(chunk(content="", finish="stop")); send(b"data: [DONE]\n\n"); return
            if model == 'same':
                send(chunk(content="<code>\n" + body['messages'][1]['content'].split('<selection>\n')[1].split('\n</selection>')[0] + "\n</code>")); send(chunk(content="", finish="stop")); send(b"data: [DONE]\n\n"); return
            if model == 'crlf':
                w.write(b'data: {"choices":[{"delta":{"content":"<code>\\nlocal y = 2\\n</code>"}}]}\r\n\r\n')
                w.write(b'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\r\n\r\ndata: [DONE]\r\n\r\n'); w.flush(); return
        except BrokenPipeError:
            pass

ThreadingHTTPServer(('127.0.0.1', 8765), H).serve_forever()
