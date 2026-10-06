#!/usr/bin/env python3
"""Build a Flash/Ruffle SharedObject (.sol) from the game's save JSON.

Why: the game POSTs its save as JSON (`onePlayerDate{...}`) but it *reads* the
save back from a SharedObject container.  This converts the JSON form into a
valid `00 BF TCSO` container so progress can be restored / migrated.

Usage:
    python build_sol.py <save.json|post-body.txt> [out_b64.txt]

Encoding strategy (deliberately simple and provably parseable):
  * every object is written as a *dynamic* object with 0 sealed members and an
    empty class name  -> 0A 0B 01 <name/value pairs> 01
  * every string is written as a literal (never interned), so the string
    reference table is never needed and cannot drift
  * ints use the 29-bit two's-complement U29 form (so -1 -> FF FF FF FF)
Round-trip verified against tools/decode_sol.py.
"""
import json
import os
import struct
import sys
from urllib.parse import parse_qs, unquote

SO_NAME = "shengbingchuanqi"
TOP_KEY = "数据"
SOL_VERSION = 0x00040000


def u29(n):
    n &= 0x1FFFFFFF
    if n < 0x80:
        return bytes([n])
    if n < 0x4000:
        return bytes([0x80 | (n >> 7), n & 0x7F])
    if n < 0x200000:
        return bytes([0x80 | (n >> 14), 0x80 | ((n >> 7) & 0x7F), n & 0x7F])
    return bytes([0x80 | (n >> 22), 0x80 | ((n >> 15) & 0x7F),
                  0x80 | ((n >> 8) & 0x7F), n & 0xFF])


def amf_str(s):
    b = s.encode("utf-8")
    return b"\x06" + u29((len(b) << 1) | 1) + b


def amf_bare_str(s):
    """Top-level SharedObject property names carry no 0x06 marker byte."""
    b = s.encode("utf-8")
    return u29((len(b) << 1) | 1) + b


def amf(v):
    if v is None:
        return b"\x01"
    if v is True:
        return b"\x03"
    if v is False:
        return b"\x02"
    if isinstance(v, int):
        return b"\x04" + u29(v)
    if isinstance(v, float):
        return b"\x05" + struct.pack(">d", v)
    if isinstance(v, str):
        return amf_str(v)
    if isinstance(v, (list, tuple)):
        return (b"\x09" + u29((len(v) << 1) | 1) + b"\x01"
                + b"".join(amf(x) for x in v))
    if isinstance(v, dict):
        body = b""
        for k, val in v.items():
            if k == "__class__":
                continue
            # property names are BARE strings in AMF3 (no 0x06 type marker);
            # only *values* carry a marker byte.
            body += amf_bare_str(str(k)) + amf(val)
        # 0A = object, 0B = inline+inline-traits+dynamic (0 sealed), 01 = ""
        return b"\x0A\x0B\x01" + body + b"\x01"
    raise TypeError("cannot encode %r" % type(v))


def load_save(path):
    raw = open(path, "r", encoding="utf-8", errors="replace").read().strip()
    if raw.startswith("{"):
        return json.loads(raw)
    # a raw POST body:  value=<urlencoded json>
    if raw.startswith("value=") or "=" in raw[:12]:
        qs = parse_qs(raw, keep_blank_values=True)
        return json.loads(unquote(qs["value"][0]))
    raise SystemExit("unrecognised save input")


def build(obj):
    amf3 = amf_bare_str(TOP_KEY) + amf(obj)
    body = (b"TCSO"
            + SOL_VERSION.to_bytes(4, "big")
            + len(SO_NAME).to_bytes(4, "big") + SO_NAME.encode()
            + b"\x00\x00\x00\x03"          # AMF version flag: 3 = AMF3
            + amf3
            + b"\x00")                     # container padding byte
    raw = b"\x00\xbf" + (len(body) + 2).to_bytes(4, "big") + body
    # length field counts everything after the 6-byte prefix
    raw = b"\x00\xbf" + (len(raw) - 6).to_bytes(4, "big") + body
    return raw


def main():
    src = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else None
    obj = load_save(src)
    raw = build(obj)
    import base64
    b64 = base64.b64encode(raw).decode()
    print("save json keys :", list(obj.keys()))
    print("container bytes:", len(raw))
    print("base64 chars   :", len(b64))
    if out:
        with open(out, "w", encoding="utf-8") as f:
            f.write(b64)
        print("wrote", out)
    else:
        print(b64)


if __name__ == "__main__":
    main()
