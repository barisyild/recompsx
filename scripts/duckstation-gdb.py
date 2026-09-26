#!/usr/bin/env python3
"""DuckStation as a behavioural oracle, through its GDB stub (docs/architecture.md, ladder step 3).

Enable it in DuckStation's settings.ini (`[Debug] EnableGDBServer = true`, `GDBServerPort = 2345`;
back the file up first and put it back afterwards), start the game, then script it from Python:

    import importlib.util, sys
    spec = importlib.util.spec_from_file_location('dsgdb', 'scripts/duckstation-gdb.py')
    dsgdb = importlib.util.module_from_spec(spec); spec.loader.exec_module(dsgdb)
    g = dsgdb.Gdb()                        # connecting pauses the machine
    g.set_break(0x8003d054); g.cont(); g.wait_stop()
    r = g.regs(); ram = g.mem(0x80000000, 0x200000)
    g.close()                              # resumes it

or from the shell:  scripts/duckstation-gdb.py regs | mem ADDR LEN OUT.bin

Behaviour of the stub, as measured on DuckStation 0.1 (2026-09): the first packet must be `?`
(answered S02; a bare 0x03 before it gets no answer); `c` has no reply until the next stop; 0x03
while running stops with S00; `s` answers `OK` and then the stop packet; `g` returns 73 words —
the 32 GPRs, then sr, lo, hi, badvaddr, cause, pc; Z0 (execution), Z2 (write), Z3 (read) and Z4
(access) all work. Nothing here reads DuckStation's source: this is the GDB remote protocol.
"""
import socket
import struct
import sys

NAMES = ("zero at v0 v1 a0 a1 a2 a3 t0 t1 t2 t3 t4 t5 t6 t7 s0 s1 s2 s3 s4 s5 s6 s7 "
         "t8 t9 k0 k1 gp sp fp ra sr lo hi bad cause pc").split()


class Gdb:
    def __init__(self, host="127.0.0.1", port=2345):
        self.s = socket.create_connection((host, port), timeout=10)
        self.buf = b""
        self.running = False
        self._send("?")
        self.stop = self._packet()

    def _send(self, payload):
        data = payload.encode()
        self.s.sendall(b"$" + data + b"#" + b"%02x" % (sum(data) & 0xFF))

    def _packet(self, timeout=10):
        self.s.settimeout(timeout)
        while True:
            i = self.buf.find(b"$")
            j = self.buf.find(b"#", i) if i >= 0 else -1
            if j >= 0 and len(self.buf) >= j + 3:
                data = self.buf[i + 1:j]
                self.buf = self.buf[j + 3:]
                self.s.sendall(b"+")
                return data.decode(errors="replace")
            chunk = self.s.recv(65536)
            if not chunk:
                raise EOFError("DuckStation closed the connection")
            self.buf += chunk

    def cmd(self, payload, timeout=10):
        self._send(payload)
        return self._packet(timeout)

    def cont(self):
        self._send("c")
        self.running = True

    def halt(self):
        if self.running:
            self.s.sendall(b"\x03")
            self.stop = self._packet()
            self.running = False
        return self.stop

    def wait_stop(self, timeout=120):
        self.stop = self._packet(timeout)
        self.running = False
        return self.stop

    def step(self):
        reply = self.cmd("s")
        if reply == "OK":
            reply = self._packet()
        self.stop = reply
        return reply

    def regs(self):
        r = self.cmd("g")
        words = [struct.unpack("<I", bytes.fromhex(r[i:i + 8]))[0] for i in range(0, len(r), 8)]
        return dict(zip(NAMES, words))

    def mem(self, addr, length):
        out = b""
        while length > 0:
            n = min(length, 0x800)
            r = self.cmd("m%x,%x" % (addr, n))
            if len(r) == 3 and r.startswith("E"):
                raise IOError("read failed at %08x: %s" % (addr, r))
            out += bytes.fromhex(r)
            addr += n
            length -= n
        return out

    def u32(self, addr):
        return struct.unpack("<I", self.mem(addr, 4))[0]

    def set_break(self, addr, kind=0):
        """kind: 0 execution, 2 write, 3 read, 4 access."""
        return self.cmd("Z%d,%x,4" % (kind, addr))

    def clear_break(self, addr, kind=0):
        return self.cmd("z%d,%x,4" % (kind, addr))

    def close(self):
        try:
            if not self.running:
                self.cont()
        finally:
            self.s.close()


def main(argv):
    if len(argv) >= 2 and argv[1] == "regs":
        g = Gdb()
        for name, value in g.regs().items():
            print("%-5s %08x" % (name, value))
        g.close()
    elif len(argv) == 5 and argv[1] == "mem":
        g = Gdb()
        data = g.mem(int(argv[2], 0), int(argv[3], 0))
        g.close()
        with open(argv[4], "wb") as f:
            f.write(data)
        print("%d bytes to %s" % (len(data), argv[4]))
    else:
        print(__doc__.strip().splitlines()[0])
        print("usage: duckstation-gdb.py regs | mem ADDR LEN OUT.bin")
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
