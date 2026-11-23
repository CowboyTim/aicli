#!/usr/bin/env python3
# Fake services for the browser checks (no model, no GPU): an OpenAI compatible chat that asks for
# the generate_image tool once, and then answers in text, and an image service (AI_IMAGE_URL) that
# answers with a 256 x 256 picture, a gradient, as PNG. Both are for the files check (files.js).
#   python3 tools/ui-check/fake-services.py LLM_PORT IMAGE_PORT
# Point the server at them with start-server.sh (AICLI_CHECK_LLM, AICLI_CHECK_IMAGE).
import base64, json, struct, sys, threading, zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def png(w, h):
    rows = []
    for y in range(h):
        row = bytearray([0])  # the filter byte of the row
        for x in range(w):
            row += bytes((x * 255 // (w - 1), y * 255 // (h - 1), 160))
        rows.append(bytes(row))

    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)

    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(b''.join(rows))) + chunk(b'IEND', b''))


def send(handler, code, ctype, body):
    handler.send_response(code)
    handler.send_header('Content-Type', ctype)
    handler.send_header('Content-Length', str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


class Llm(BaseHTTPRequestHandler):
    def do_GET(self):  # the model list
        send(self, 200, 'application/json', b'{"data":[{"id":"fake-model"}]}')

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))) or b'{}')
        messages = body.get('messages', [])
        events = []
        if body.get('tools') and not any(m.get('role') == 'tool' for m in messages):
            args = {'prompt': 'a cube', 'output': 'live.png', 'size': '256x256', 'steps': '2'}
            events.append({'choices': [{'delta': {'tool_calls': [{'index': 0, 'id': 'call_live', 'type': 'function',
                'function': {'name': 'generate_image', 'arguments': json.dumps(args)}}]}}]})
            events.append({'choices': [{'delta': {}, 'finish_reason': 'tool_calls'}]})
        else:
            events.append({'choices': [{'delta': {'content': 'Here is the picture.'}}]})
            events.append({'choices': [{'delta': {}, 'finish_reason': 'stop'}]})
        out = ''.join('data: %s\n\n' % json.dumps(e) for e in events) + 'data: [DONE]\n\n'
        send(self, 200, 'text/event-stream', out.encode())

    def log_message(self, *a):
        pass


class Image(BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length', 0)))
        reply = {'data': [{'b64_json': base64.b64encode(png(256, 256)).decode()}]}
        send(self, 200, 'application/json', json.dumps(reply).encode())

    def log_message(self, *a):
        pass


def serve(port, handler):
    ThreadingHTTPServer(('127.0.0.1', port), handler).serve_forever()


if __name__ == '__main__':
    llm_port, image_port = int(sys.argv[1]), int(sys.argv[2])
    threading.Thread(target=serve, args=(image_port, Image), daemon=True).start()
    serve(llm_port, Llm)
