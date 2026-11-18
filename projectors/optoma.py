#!/usr/bin/env python3
"""Optoma projector status reporter for Home Assistant.

Keeps the RS232 port open continuously so the projector's unsolicited INFO messages are never
missed, polls the Information query for power and lamp hours, and pushes the state to a Home
Assistant webhook whenever it changes (plus a periodic heartbeat).

Standard library only, compatible with Python 3.5 (Raspbian stretch).

States pushed:  Standby | Warming Up | Power On | Cooling Down
  INFO1 -> Warming Up, INFO2 -> Cooling Down, INFO0 -> Standby (sent by the projector on change)
  ~XX150 1 reply "OKa..." -> a=1 Power On, a=0 Standby (polled; ignored while Cooling Down)
Error field:    "No Error" | "Signal out of range" (INFO3) | "INFO<n>" for any other INFO code

Usage: optoma.py <config.json>
Config keys: "port" (e.g. /dev/ttyUSB0), "webhook_url" (http://<ha>:8123/api/webhook/<id>),
             optional "projector_id" (default "00").
"""
import json
import os
import select
import sys
import termios
import time
import urllib.request

POLL_WARMING = 2        # seconds between power polls while warming up (catch Power On fast)
POLL_NORMAL = 30        # seconds between polls otherwise (resync + lamp hours)
HEARTBEAT = 300         # re-push the current state at least this often
COOLING_TIMEOUT = 120   # if no INFO0 arrives, trust the poll again after this long
INFO_STATES = {"0": "Standby", "1": "Warming Up", "2": "Cooling Down"}
INFO_ERRORS = {"3": "Signal out of range"}


def log(msg):
    print(time.strftime("%Y-%m-%d %H:%M:%S"), msg, flush=True)


def open_port(dev):
    fd = os.open(dev, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    a = termios.tcgetattr(fd)
    a[0] = 0                                                # iflag: raw
    a[1] = 0                                                # oflag: raw
    a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL     # 8N1, no flow control
    a[3] = 0                                                # lflag: raw
    a[4] = a[5] = termios.B9600
    a[6][termios.VMIN] = 0
    a[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, a)
    termios.tcflush(fd, termios.TCIOFLUSH)
    return fd


class Reporter(object):
    def __init__(self, cfg):
        self.port = cfg["port"]
        self.url = cfg["webhook_url"]
        self.pid = cfg.get("projector_id", "00")
        self.state = None
        self.error = "No Error"
        self.lamp = None
        self.cooling_since = None
        self.last_push = 0
        self.last_pushed = None
        self.next_poll = 0
        self.buf = b""

    # ---- Home Assistant ----
    def push(self, force=False):
        payload = {"state": self.state, "error": self.error, "lamp_hours": self.lamp}
        if not force and payload == self.last_pushed:
            return
        if self.state is None:
            return
        data = json.dumps(payload).encode()
        req = urllib.request.Request(self.url, data=data, headers={"Content-Type": "application/json"}, method="POST")
        try:
            urllib.request.urlopen(req, timeout=10).read()
            self.last_pushed = payload
            self.last_push = time.time()
            log("pushed %s" % json.dumps(payload))
        except Exception as e:  # keep running; the next change or heartbeat retries
            log("push failed: %s" % e)

    def set_state(self, state, why):
        if state == "Cooling Down":
            self.cooling_since = time.time()
        elif state != "Cooling Down":
            self.cooling_since = None
        if state != self.state:
            log("state %s -> %s (%s)" % (self.state, state, why))
            self.state = state
            self.error = "No Error"  # INFO3 etc. have no "cleared" message; reset on every state change
            if state == "Warming Up":
                self.next_poll = time.time() + POLL_WARMING
        self.push()

    # ---- projector ----
    def poll(self, fd):
        os.write(fd, ("~%s150 1\r" % self.pid).encode())
        self.next_poll = time.time() + (POLL_WARMING if self.state == "Warming Up" else POLL_NORMAL)

    def handle_line(self, line):
        if not line:
            return
        if line.startswith("INFO") and len(line) >= 5:
            code = line[4:]
            if code in INFO_STATES:
                self.set_state(INFO_STATES[code], line)
            else:
                self.error = INFO_ERRORS.get(code, line)
                log("projector reported %s (%s)" % (line, self.error))
                self.push()
            return
        if line[:2].upper() == "OK" and len(line) >= 8 and line[2] in "01" and line[3:8].isdigit():
            power = line[2]
            lamp = int(line[3:8], 10)
            if lamp > 0:
                self.lamp = lamp
            if power == "1":
                if self.state != "Power On":
                    self.set_state("Power On", "poll power=1")
                else:
                    self.push()
            else:
                cooling = self.cooling_since is not None and time.time() - self.cooling_since < COOLING_TIMEOUT
                if self.state == "Warming Up":
                    pass  # power flag may lag at start-up; wait for power=1 or another INFO
                elif not cooling:
                    self.set_state("Standby", "poll power=0")
                else:
                    self.push()
            return
        # "P" (pass), "F" (fail / unsupported), stray bytes: ignore

    def read(self, fd):
        try:
            data = os.read(fd, 4096)
        except BlockingIOError:
            return
        self.buf += data.replace(b"\x00", b"")
        while b"\r" in self.buf:
            raw, self.buf = self.buf.split(b"\r", 1)
            self.handle_line(raw.decode("ascii", "replace").strip())
        if len(self.buf) > 256:     # never grow without bound on garbage
            self.buf = b""

    def run(self):
        fd = open_port(self.port)
        log("listening on %s, pushing to %s" % (self.port, self.url.split("/api/webhook/")[0] + "/api/webhook/***"))
        self.poll(fd)
        while True:
            now = time.time()
            timeout = max(0.0, min(self.next_poll, self.last_push + HEARTBEAT) - now)
            r, _, _ = select.select([fd], [], [], min(timeout, 1.0))
            if r:
                self.read(fd)
            now = time.time()
            if now >= self.next_poll:
                self.poll(fd)
            if self.state is not None and now - self.last_push >= HEARTBEAT:
                self.push(force=True)


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: %s <config.json>" % sys.argv[0])
    with open(sys.argv[1]) as f:
        cfg = json.load(f)
    for k in ("port", "webhook_url"):
        if not cfg.get(k):
            sys.exit('config is missing "%s"' % k)
    Reporter(cfg).run()


if __name__ == "__main__":
    main()
