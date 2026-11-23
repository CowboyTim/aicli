#!/usr/bin/env python3
# Fake services for the browser checks (no model, no GPU): an OpenAI compatible chat that asks for
# the generate_image tool for each new message of the user, and answers in text after a tool result, and an
# image service (AI_IMAGE_URL) that
# answers with a 256 x 256 picture, a gradient, as PNG. Both are for the files check (files.js).
#   python3 tools/ui-check/fake-services.py LLM_PORT IMAGE_PORT [AUDIO_PORT]
# and an audio service (AI_AUDIO_URL, the generate_audio tool) that answers with a short WAV clip. Point the
# server at them with start-server.sh (AICLI_CHECK_LLM, AICLI_CHECK_IMAGE, AICLI_CHECK_AUDIO).
import base64, json, math, struct, sys, threading, zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def png(w, h, blue=160):
    rows = []
    for y in range(h):
        row = bytearray([0])  # the filter byte of the row
        for x in range(w):
            row += bytes((x * 255 // (w - 1), y * 255 // (h - 1), blue))
        rows.append(bytes(row))

    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)

    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(b''.join(rows))) + chunk(b'IEND', b''))


def wav(seconds=1, rate=8000):
    # a 440 Hz tone, 16 bit mono
    n = int(seconds * rate)
    pcm = b''.join(struct.pack('<h', int(12000 * math.sin(2 * math.pi * 440 * i / rate))) for i in range(n))
    fmt = struct.pack('<HHIIHH', 1, 1, rate, rate * 2, 2, 16)
    body = b'WAVE' + b'fmt ' + struct.pack('<I', len(fmt)) + fmt + b'data' + struct.pack('<I', len(pcm)) + pcm
    return b'RIFF' + struct.pack('<I', len(body)) + body


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
        # a tool call for each new message of the user (a message after a tool result is answered in text)
        if body.get('tools') and messages and messages[-1].get('role') != 'tool' and 'sound' in next(
                (m.get('content') or '' for m in reversed(messages) if m.get('role') == 'user'), ''):
            # "sound" in the message: one call of generate_audio
            args = {'prompt': 'waves', 'output': 'clip.wav', 'seconds': '1'}
            events.append({'choices': [{'delta': {'tool_calls': [{'index': 0, 'id': 'call_sound', 'type': 'function',
                'function': {'name': 'generate_audio', 'arguments': json.dumps(args)}}]}}]})
            events.append({'choices': [{'delta': {}, 'finish_reason': 'tool_calls'}]})
        elif body.get('tools') and messages and messages[-1].get('role') != 'tool' and 'copy' in next(
                (m.get('content') or '' for m in reversed(messages) if m.get('role') == 'user'), ''):
            # "copy" in the message: a bash call that makes a picture (no image tool, the way a model may do it)
            args = {'code': 'cp live.png copy.png'}
            events.append({'choices': [{'delta': {'tool_calls': [{'index': 0, 'id': 'call_copy', 'type': 'function',
                'function': {'name': 'bash', 'arguments': json.dumps(args)}}]}}]})
            events.append({'choices': [{'delta': {}, 'finish_reason': 'tool_calls'}]})
        elif body.get('tools') and messages and messages[-1].get('role') != 'tool':
            # "two" in the message asks for two pictures in one answer: both calls at index 0, as some
            # servers send them, with an id each
            last = next((m.get('content') or '' for m in reversed(messages) if m.get('role') == 'user'), '')
            n = 1 + sum(1 for m in messages if m.get('role') == 'tool')
            if 'two' in last:
                outputs = ['pair-1.png', 'pair-2.png']
            else:
                outputs = ['live.png']
            calls = []
            for k, output in enumerate(outputs):
                args = {'prompt': 'a cube', 'output': output, 'size': '256x256', 'steps': '2'}
                calls.append({'index': 0, 'id': 'call_%d_%d' % (n, k), 'type': 'function',
                              'function': {'name': 'generate_image', 'arguments': json.dumps(args)}})
            for c in calls:
                events.append({'choices': [{'delta': {'tool_calls': [c]}}]})
            events.append({'choices': [{'delta': {}, 'finish_reason': 'tool_calls'}]})
        else:
            events.append({'choices': [{'delta': {'content': 'Here is the picture.'}}]})
            events.append({'choices': [{'delta': {}, 'finish_reason': 'stop'}]})
        out = ''.join('data: %s\n\n' % json.dumps(e) for e in events) + 'data: [DONE]\n\n'
        send(self, 200, 'text/event-stream', out.encode())

    def log_message(self, *a):
        pass


class Audio(BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length', 0)))
        send(self, 200, 'audio/wav', wav(1))

    def log_message(self, *a):
        pass


class Image(BaseHTTPRequestHandler):
    count = 0  # each picture has its own blue, so two pictures can be told apart

    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length', 0)))
        Image.count += 1
        reply = {'data': [{'b64_json': base64.b64encode(png(256, 256, 40 + (Image.count * 50) % 200)).decode()}]}
        send(self, 200, 'application/json', json.dumps(reply).encode())

    def log_message(self, *a):
        pass


def serve(port, handler):
    ThreadingHTTPServer(('127.0.0.1', port), handler).serve_forever()


if __name__ == '__main__':
    llm_port, image_port = int(sys.argv[1]), int(sys.argv[2])
    audio_port = int(sys.argv[3]) if len(sys.argv) > 3 else 8782
    threading.Thread(target=serve, args=(image_port, Image), daemon=True).start()
    threading.Thread(target=serve, args=(audio_port, Audio), daemon=True).start()
    serve(llm_port, Llm)
