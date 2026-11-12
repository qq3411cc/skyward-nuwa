#!/usr/bin/env python3
"""Take one partition out of a full OTA zip over HTTP range requests.

Reads only the zip's central directory, the payload manifest and the data
blobs belonging to the wanted partition, so a 7 GB package costs a few
hundred MB of traffic.

Usage:
  payload_get.py URL PARTITION OUT [--sha256 EXPECTED]
"""
import argparse
import bz2
import hashlib
import lzma
import struct
import sys
import urllib.request

CHUNK = 1 << 22


class Http:
    def __init__(self, url):
        self.url = url

    def get(self, start, end):
        req = urllib.request.Request(self.url, headers={"Range": f"bytes={start}-{end}"})
        with urllib.request.urlopen(req, timeout=120) as r:
            return r.read()

    def size(self):
        req = urllib.request.Request(self.url, method="HEAD")
        with urllib.request.urlopen(req, timeout=60) as r:
            return int(r.headers["Content-Length"])


def u16(b, o):
    return struct.unpack_from("<H", b, o)[0]


def u32(b, o):
    return struct.unpack_from("<I", b, o)[0]


def u64(b, o):
    return struct.unpack_from("<Q", b, o)[0]


def zip_entries(http, size):
    tail = http.get(max(0, size - 200000), size - 1)
    i = tail.rfind(b"PK\x05\x06")
    if i < 0:
        raise SystemExit("no end of central directory")
    count = u16(tail, i + 10)
    cd_size = u32(tail, i + 12)
    cd_off = u32(tail, i + 16)
    if cd_off == 0xFFFFFFFF or cd_size == 0xFFFFFFFF or count == 0xFFFF:
        j = tail.rfind(b"PK\x06\x07")
        if j < 0:
            raise SystemExit("no zip64 locator")
        eocd64 = u64(tail, j + 8)
        rec = http.get(eocd64, eocd64 + 55)
        if rec[:4] != b"PK\x06\x06":
            raise SystemExit("bad zip64 eocd")
        count = u64(rec, 32)
        cd_size = u64(rec, 40)
        cd_off = u64(rec, 48)
    cd = http.get(cd_off, cd_off + cd_size - 1)
    out = {}
    p = 0
    while p + 46 <= len(cd) and cd[p:p + 4] == b"PK\x01\x02":
        method = u16(cd, p + 10)
        csz = u32(cd, p + 20)
        usz = u32(cd, p + 24)
        nl = u16(cd, p + 28)
        el = u16(cd, p + 30)
        cl = u16(cd, p + 32)
        lho = u32(cd, p + 42)
        name = cd[p + 46:p + 46 + nl].decode("utf-8", "replace")
        extra = cd[p + 46 + nl:p + 46 + nl + el]
        if csz == 0xFFFFFFFF or usz == 0xFFFFFFFF or lho == 0xFFFFFFFF:
            q = 0
            while q + 4 <= len(extra):
                tag = u16(extra, q)
                ln = u16(extra, q + 2)
                body = extra[q + 4:q + 4 + ln]
                if tag == 1:
                    r = 0
                    if usz == 0xFFFFFFFF:
                        usz = u64(body, r); r += 8
                    if csz == 0xFFFFFFFF:
                        csz = u64(body, r); r += 8
                    if lho == 0xFFFFFFFF:
                        lho = u64(body, r); r += 8
                q += 4 + ln
        out[name] = (method, csz, usz, lho)
        p += 46 + nl + el + cl
    return out


def read_pb(buf, p):
    """One protobuf field: (field_number, wire_type, value, next_offset)."""
    key, p = read_varint(buf, p)
    fn, wt = key >> 3, key & 7
    if wt == 0:
        v, p = read_varint(buf, p)
        return fn, wt, v, p
    if wt == 1:
        return fn, wt, buf[p:p + 8], p + 8
    if wt == 2:
        ln, p = read_varint(buf, p)
        return fn, wt, buf[p:p + ln], p + ln
    if wt == 5:
        return fn, wt, buf[p:p + 4], p + 4
    raise SystemExit(f"wire type {wt}")


def read_varint(buf, p):
    v = 0
    shift = 0
    while True:
        b = buf[p]
        p += 1
        v |= (b & 0x7F) << shift
        if not b & 0x80:
            return v, p
        shift += 7


def fields(buf):
    p = 0
    while p < len(buf):
        fn, wt, v, p = read_pb(buf, p)
        yield fn, wt, v


def parse_manifest(man):
    partitions = []
    for fn, wt, v in fields(man):
        if fn == 13 and wt == 2:
            part = {"name": None, "size": None, "ops": []}
            for f2, w2, v2 in fields(v):
                if f2 == 1 and w2 == 2:
                    part["name"] = v2.decode()
                elif f2 == 7 and w2 == 2:
                    # new_partition_info: size is its first field
                    for f3, w3, v3 in fields(v2):
                        if f3 == 1 and w3 == 0:
                            part["size"] = v3
                            break
                elif f2 == 8 and w2 == 2:
                    op = {"type": 0, "off": 0, "len": 0, "dst": []}
                    for f3, w3, v3 in fields(v2):
                        if f3 == 1 and w3 == 0:
                            op["type"] = v3
                        elif f3 == 2 and w3 == 0:
                            op["off"] = v3
                        elif f3 == 3 and w3 == 0:
                            op["len"] = v3
                        elif f3 == 6 and w3 == 2:
                            dst = {"blocks": 0, "start": 0}
                            for f4, w4, v4 in fields(v3):
                                if f4 == 1 and w4 == 0:
                                    dst["start"] = v4
                                elif f4 == 2 and w4 == 0:
                                    dst["blocks"] = v4
                            op["dst"].append(dst)
                    part["ops"].append(op)
            partitions.append(part)
    return partitions


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("url")
    ap.add_argument("partition")
    ap.add_argument("out")
    ap.add_argument("--sha256")
    args = ap.parse_args()

    http = Http(args.url)
    size = http.size()
    print(f"package {size} bytes")
    entries = zip_entries(http, size)
    if "payload.bin" not in entries:
        raise SystemExit("no payload.bin in package")
    method, csz, usz, lho = entries["payload.bin"]
    print(f"payload.bin method={method} stored={csz} unpacked={usz}")
    if method != 0:
        raise SystemExit("payload.bin is compressed in the zip, not supported")

    head = http.get(lho, lho + 4095)
    if head[:4] == b"PK\x03\x04":
        nl, el = u16(head, 26), u16(head, 28)
        lho = lho + 30 + nl + el
        head = http.get(lho, lho + 4095)
    if head[:4] != b"CrAU":
        raise SystemExit("payload.bin has no CrAU magic")
    # the payload header is big-endian: magic, version, manifest size, then the
    # metadata signature's size
    version = struct.unpack_from(">Q", head, 4)[0]
    man_size = struct.unpack_from(">Q", head, 12)[0]
    meta_sig = struct.unpack_from(">I", head, 20)[0]
    print(f"payload version {version} manifest {man_size} metadata signature {meta_sig}")
    data_start = lho + 24 + man_size + meta_sig
    man = http.get(lho + 24, lho + 24 + man_size - 1)
    partitions = parse_manifest(man)
    part = next((p for p in partitions if p["name"] == args.partition), None)
    if part is None:
        raise SystemExit(f"{args.partition} not in package; have {[p['name'] for p in partitions]}")
    ops = [o for o in part["ops"] if o["len"] or o["dst"]]
    print(f"{args.partition}: size={part['size']} ops={len(ops)} types={sorted({o['type'] for o in ops})}")

    out = bytearray(part["size"] or 0)
    # fetch the blobs the partition needs as one contiguous window, then slice
    ops = [o for o in ops if o["len"]]
    lo = min(o["off"] for o in ops)
    hi = max(o["off"] + o["len"] for o in ops)
    print(f"blobs {lo}..{hi} ({hi - lo} bytes)", flush=True)
    blob_all = bytearray()
    step = CHUNK
    pos = lo
    while pos < hi:
        end = min(pos + step - 1, hi - 1)
        blob_all += http.get(data_start + pos, data_start + end)
        pos = end + 1
        print(f"  {len(blob_all)}/{hi - lo}", flush=True)
    for o in ops:
        blob = bytes(blob_all[o["off"] - lo:o["off"] - lo + o["len"]])
        if o["type"] == 8:      # REPLACE_XZ
            blob = lzma.decompress(blob)
        elif o["type"] == 1:    # REPLACE_BZ
            blob = bz2.decompress(blob)
        elif o["type"] != 0:
            raise SystemExit(f"operation type {o['type']} not supported")
        q = 0
        for d in o["dst"]:
            n = d["blocks"] * 4096
            seg = blob[q:q + n]
            at = d["start"] * 4096
            out[at:at + len(seg)] = seg
            q += n
        if q > len(blob):
            print(f"  op at {o['off']} names {q} bytes of blocks but holds {len(blob)}", flush=True)
    if part["size"] and len(out) > part["size"]:
        out = out[:part["size"]]
    open(args.out, "wb").write(bytes(out))
    sum_ = hashlib.sha256(out).hexdigest()
    print(f"wrote {args.out} {len(out)} bytes sha256={sum_}")
    if args.sha256:
        print("MATCH" if sum_ == args.sha256 else f"MISMATCH expected {args.sha256}")
        return 0 if sum_ == args.sha256 else 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
