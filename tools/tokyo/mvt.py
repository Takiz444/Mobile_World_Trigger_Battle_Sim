"""Minimal Mapbox Vector Tile (protobuf) decoder, pure Python.

decode(data) -> {layer_name: {"extent": int, "features": [
    {"id": int, "type": 1|2|3, "props": {...}, "rings": [[(x, y), ...], ...]}]}}

Coordinates are tile-local (0..extent, y down). Polygon rings keep their
winding (exterior rings positive area in tile coordinates per the spec).
"""


def _varint(buf, i):
    shift = 0
    result = 0
    while True:
        b = buf[i]
        i += 1
        result |= (b & 0x7F) << shift
        if not b & 0x80:
            return result, i
        shift += 7


def _fields(buf):
    """Yields (field number, wire type, value) of a protobuf message."""
    i = 0
    n = len(buf)
    while i < n:
        key, i = _varint(buf, i)
        field, wire = key >> 3, key & 7
        if wire == 0:
            v, i = _varint(buf, i)
        elif wire == 1:
            v = buf[i:i + 8]
            i += 8
        elif wire == 2:
            ln, i = _varint(buf, i)
            v = buf[i:i + ln]
            i += ln
        elif wire == 5:
            v = buf[i:i + 4]
            i += 4
        else:
            raise ValueError("unsupported wire type %d" % wire)
        yield field, wire, v


def _packed(buf):
    out = []
    i = 0
    while i < len(buf):
        v, i = _varint(buf, i)
        out.append(v)
    return out


def _zigzag(n):
    return (n >> 1) ^ -(n & 1)


def _value(buf):
    import struct
    for field, wire, v in _fields(buf):
        if field == 1:
            return bytes(v).decode("utf-8", "replace")
        if field == 2:
            return struct.unpack("<f", bytes(v))[0]
        if field == 3:
            return struct.unpack("<d", bytes(v))[0]
        if field in (4, 5):
            return v if field == 5 or v < (1 << 63) else v - (1 << 64)
        if field == 6:
            return _zigzag(v)
        if field == 7:
            return bool(v)
    return None


def _geometry(cmds):
    rings = []
    cur = []
    x = y = 0
    i = 0
    while i < len(cmds):
        c = cmds[i]
        i += 1
        cid, count = c & 7, c >> 3
        if cid == 1 or cid == 2:
            for _ in range(count):
                x += _zigzag(cmds[i])
                y += _zigzag(cmds[i + 1])
                i += 2
                if cid == 1:
                    if cur:
                        rings.append(cur)
                    cur = [(x, y)]
                else:
                    cur.append((x, y))
        elif cid == 7:
            if cur:
                rings.append(cur)
            cur = []
    if cur:
        rings.append(cur)
    return rings


def decode(data):
    layers = {}
    for field, wire, v in _fields(memoryview(data)):
        if field != 3:
            continue
        name = ""
        extent = 4096
        keys = []
        values = []
        raw_features = []
        for f2, w2, v2 in _fields(v):
            if f2 == 1:
                name = bytes(v2).decode("utf-8", "replace")
            elif f2 == 2:
                raw_features.append(v2)
            elif f2 == 3:
                keys.append(bytes(v2).decode("utf-8", "replace"))
            elif f2 == 4:
                values.append(_value(v2))
            elif f2 == 5:
                extent = v2
        feats = []
        for fb in raw_features:
            fid = 0
            ftype = 0
            tags = []
            geom = []
            for f3, w3, v3 in _fields(fb):
                if f3 == 1:
                    fid = v3
                elif f3 == 2:
                    tags = _packed(v3)
                elif f3 == 3:
                    ftype = v3
                elif f3 == 4:
                    geom = _packed(v3)
            props = {}
            for k in range(0, len(tags) - 1, 2):
                if tags[k] < len(keys) and tags[k + 1] < len(values):
                    props[keys[tags[k]]] = values[tags[k + 1]]
            feats.append({"id": fid, "type": ftype, "props": props, "rings": _geometry(geom)})
        layers[name] = {"extent": extent, "features": feats}
    return layers
