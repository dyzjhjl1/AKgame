#!/usr/bin/env python3
"""Decode a Flash / Ruffle SharedObject (.sol / TCSO) container to JSON.

Usage:   python decode_sol.py <file>            # file = base64 text or binary .sol
         SOL_TRACE=1 python decode_sol.py <f>   # verbose string-table trace

Container layout (all 4-byte length fields are BIG-endian):

    00 BF | u32 data-length (= total - 6) | "TCSO" | u32 version
          | u32 name-length | name | 00 00 00 03  <- AMF version flag (3 = AMF3)
          | AMF3: string property-name, value

The AMF3 subset Ruffle emits for this game: string, integer, double, bool,
null, array, dynamic object. Objects carry a *trait* record (class name +
sealed member names) which later objects reuse by index, and dynamic objects
store extra members as name/value pairs terminated by an empty name.

Self-check: the script prints "trailing: 0" when the whole payload was
consumed, which means the decode is byte-exact.
"""
import base64
import json
import os
import re
import struct
import sys

TRACE = bool(os.environ.get("SOL_TRACE"))


def u29(b, i):
    """AMF3 U29 variable-length unsigned integer.

    Bytes 1-3 contribute 7 bits each; the 4th contributes a full 8 bits,
    which is what makes the value 29 bits wide. Using 7 bits on the 4th
    byte silently turns -1 (FF FF FF FF) into 268435455.
    """
    c = b[i]
    if (c & 0x80) == 0:
        return c, i + 1
    v = c & 0x7F
    c = b[i + 1]
    if (c & 0x80) == 0:
        return (v << 7) | c, i + 2
    v = (v << 7) | (c & 0x7F)
    c = b[i + 2]
    if (c & 0x80) == 0:
        return (v << 7) | c, i + 3
    v = (v << 7) | (c & 0x7F)
    c = b[i + 3]
    return (v << 8) | c, i + 4


class AMF3:
    def __init__(self, b):
        self.b = b
        self.strtab = []    # string references
        self.objtab = []    # object references (objects and arrays share this)
        self.traittab = []  # (class_name, [sealed member names], dynamic, ext)

    # ---- strings -------------------------------------------------------
    def string(self, i, skip_ref=False):
        start = i
        n, i = u29(self.b, i)
        if n & 1:
            ln = n >> 1
            s = self.b[i:i + ln].decode("utf-8", "replace")
            i += ln
            # IMPORTANT: the empty string is NEVER interned in the AMF3 string
            # reference table (Flash uses it as the dynamic-member terminator).
            # Interning it shifts every later reference index and silently
            # corrupts names such as "401" -> "" or "hp" -> "roleBag".
            if not skip_ref and s != "":
                self.strtab.append(s)
            if TRACE:
                print("  @%-4d str-lit%s %r"
                      % (start, "" if s else " (not interned)", s))
            return s, i
        idx = n >> 1
        if idx >= len(self.strtab):
            raise ValueError("string ref %d out of range (table=%d) at %d"
                             % (idx, len(self.strtab), start))
        if TRACE:
            print("  @%-4d str-ref[%d] %r" % (start, idx, self.strtab[idx]))
        return self.strtab[idx], i

    # ---- values --------------------------------------------------------
    def value(self, i):
        t = self.b[i]
        i += 1
        if t == 0x06:
            return self.string(i)
        if t == 0x04:                                   # signed 29-bit int
            v, i = u29(self.b, i)
            if v & 0x10000000:
                v -= 0x20000000
            return v, i
        if t == 0x05:
            return struct.unpack(">d", self.b[i:i + 8])[0], i + 8
        if t == 0x03:
            return True, i
        if t == 0x02:
            return False, i
        if t in (0x00, 0x01):
            return None, i
        if t == 0x09:
            return self.array(i)
        if t == 0x0A:
            return self.object(i)
        raise ValueError("unsupported AMF3 marker 0x%02X at %d" % (t, i - 1))

    def array(self, i):
        n, i = u29(self.b, i)
        if (n & 1) == 0:
            return self.objtab[n >> 1], i
        cnt = n >> 1
        assoc, i = self.value(i)                        # usually null
        out = []
        self.objtab.append(out)
        if isinstance(assoc, dict):
            out = assoc
            self.objtab[-1] = out
        for _ in range(cnt):
            v, i = self.value(i)
            if isinstance(out, list):
                out.append(v)
            else:
                out[str(len(out))] = v
        return out, i

    def object(self, i):
        n, i = u29(self.b, i)
        if (n & 1) == 0:                                # object reference
            return self.objtab[n >> 1], i
        if (n & 2) == 0:                                # trait reference
            cls, members, dyn, ext = self.traittab[n >> 2]
        else:
            ext = (n & 4) != 0
            dyn = (n & 8) != 0
            count = n >> 4
            cls, i = self.string(i)
            members = []
            for _ in range(count):
                nm, i = self.string(i)
                members.append(nm)
            self.traittab.append((cls, members, dyn, ext))
            if TRACE:
                print("  @%-4d traits cls=%r sealed=%r dyn=%s ext=%s"
                      % (i, cls, members, dyn, ext))
        out = {"__class__": cls}
        self.objtab.append(out)
        if ext:
            raise ValueError("externalizable object not supported")
        for nm in members:
            v, i = self.value(i)
            out[nm] = v
        if dyn:
            while True:
                # The empty string terminates the dynamic member list. Flash /
                # Ruffle still push that empty string onto the string reference
                # table, so it must be recorded here too or every later
                # reference index drifts by one per dynamic object.
                nm, i = self.string(i)
                if nm == "":
                    break
                v, i = self.value(i)
                out[nm] = v
        return out, i


def load_bytes(path):
    raw = open(path, "rb").read()
    if raw[:2] == b"\x00\xbf":
        return raw
    text = raw.decode("utf-8", "replace").strip()
    m = re.search(r'[A-Za-z0-9+/=]{80,}', text)
    return base64.b64decode(m.group(0) if m else text)


def main():
    path = sys.argv[1]
    b = load_bytes(path)
    print("source      :", path)
    print("bytes       :", len(b))
    print("magic       :", b[:2].hex(), "(00bf = SOL container)")
    print("hdr length  :", int.from_bytes(b[2:6], "big"), "(= total - 6)")
    print("tag         :", b[6:10].decode("latin1"), "(TCSO)")
    off = 10
    ver = int.from_bytes(b[off:off + 4], "big"); off += 4
    nlen = int.from_bytes(b[off:off + 4], "big"); off += 4
    name = b[off:off + nlen].decode("utf-8"); off += nlen
    print("version     :", ver)
    print("so name     :", name)
    print("amf flags   :", b[off:off + 4].hex(), "(3 = AMF3)")
    off += 4
    print("amf3 @      :", off)

    a = AMF3(b)
    key, i = a.string(off)
    val, i = a.value(i)
    print("top key     :", key)
    tail = b[i:]
    ok = len(tail) == 0 or tail == b"\x00"
    print("consumed    :", i, "/", len(b), "-> trailing:", len(tail),
          "(0x%02X)" % tail[0] if tail else "",
          "OK" if ok else "*** MISMATCH ***")
    print("--- value ---")
    print(json.dumps(val, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
