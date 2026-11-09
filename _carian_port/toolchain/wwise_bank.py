"""Minimal Wwise SoundBank (v135, Elden Ring) reader for the Carian sound port.

Finds Play events by name (FNV-1 hash), follows Event -> Action -> node tree
and lists the media (.wem) each event can play: embedded (DIDX/DATA of the
bank) or streamed (sd archive /wem/NN/<id>.wem). Only the fields needed for
that walk are parsed; every node's DirectParentID is located with a check
against the known object ids instead of a full property parser.

Usage: python wwise_bank.py <bank.bnk> <event names...>
"""
import struct, sys, json

HIRC_SOUND, HIRC_ACTION, HIRC_EVENT = 2, 3, 4
# AkPropID values used here (v135). 14 = CenterPCT and 23 = GameAuxSendVolume
# (reverb send) also appear on these nodes but are not reproduced.
PROP_VOLUME, PROP_PITCH, PROP_LOOP = 0, 2, 58


def fnv1(name):
    h = 2166136261
    for c in name.lower().encode('ascii'):
        h = (h * 16777619) & 0xFFFFFFFF
        h ^= c
    return h


def read_var(b, o):
    v = 0
    while True:
        x = b[o]; o += 1
        v = (v << 7) | (x & 0x7F)
        if not x & 0x80:
            return v, o


class Bank:
    def __init__(self, path):
        self.b = b = open(path, 'rb').read()
        self.sections = {}
        o = 0
        while o + 8 <= len(b):
            tag = b[o:o + 4].decode('latin1'); size = struct.unpack_from('<I', b, o + 4)[0]
            self.sections[tag] = (o + 8, size)
            o += 8 + size
        self.version = struct.unpack_from('<I', b, self.sections['BKHD'][0])[0]
        self.didx = {}
        if 'DIDX' in self.sections:
            do, ds = self.sections['DIDX']
            for i in range(ds // 12):
                wid, off, size = struct.unpack_from('<III', b, do + i * 12)
                self.didx[wid] = (off, size)
        self.objects = {}
        ho, hs = self.sections['HIRC']
        cnt = struct.unpack_from('<I', b, ho)[0]
        o = ho + 4
        for _ in range(cnt):
            t = b[o]; sz = struct.unpack_from('<I', b, o + 1)[0]
            oid = struct.unpack_from('<I', b, o + 5)[0]
            self.objects[oid] = (t, o + 5, sz)
            o += 5 + sz
        self._parents = None

    def embedded(self, wid):
        off, size = self.didx[wid]
        d = self.sections['DATA'][0]
        return self.b[d + off:d + off + size]

    def event_actions(self, eid):
        t, o, sz = self.objects[eid]
        assert t == HIRC_EVENT
        n, p = read_var(self.b, o + 4)
        return [struct.unpack_from('<I', self.b, p + 4 * i)[0] for i in range(n)]

    def action(self, aid):
        t, o, sz = self.objects[aid]
        assert t == HIRC_ACTION
        atype, target = struct.unpack_from('<HI', self.b, o + 4)
        return atype, target

    def sound_source(self, sid):
        """(plugin id, stream type, wem id, in-memory size) of a Sound object"""
        t, o, sz = self.objects[sid]
        plugin, stream, wem, mem = struct.unpack_from('<IBII', self.b, o + 4)
        return plugin, stream, wem, mem

    def _parent_of(self, oid):
        t, o, sz = self.objects[oid]
        b = self.b
        p = o + 4
        if t == HIRC_SOUND:
            p += 14  # AkBankSourceData (no plugin payload for codec sources)
        elif t not in (5, 6, 7, 9):
            return None
        # NodeInitialFxParams
        p += 1
        nfx = b[p]; p += 1
        if nfx:
            p += 1 + nfx * 7
        # bOverrideAttachmentParams exists from some 2019 version on: accept the
        # layout whose DirectParentID is a known node (or 0)
        for skip in (1, 0):
            q = p + skip + 4
            if q + 4 > o + sz:
                continue
            parent = struct.unpack_from('<I', b, q)[0]
            if parent == 0 or (parent in self.objects and self.objects[parent][0] in (5, 6, 7, 9, 10, 11, 12, 13)):
                return parent
        return None

    def parents(self):
        if self._parents is None:
            self._parents = {oid: self._parent_of(oid) for oid, (t, _, _) in self.objects.items() if t in (2, 5, 6, 7, 9)}
        return self._parents

    def sounds_under(self, node):
        par = self.parents()
        out = []
        for oid, (t, _, _) in self.objects.items():
            if t != HIRC_SOUND:
                continue
            p, seen = oid, 0
            while p and seen < 32:
                if p == node:
                    out.append(oid); break
                p = par.get(p); seen += 1
        return out

    def props(self, oid):
        """NodeInitialParams property bundle {prop id: float}: 0 = volume (dB), 2 = pitch (cents)."""
        t, o, sz = self.objects[oid]
        b = self.b
        p = o + 4
        if t == HIRC_SOUND:
            p += 14
        elif t not in (5, 6, 7, 9):
            return {}
        p += 1
        nfx = b[p]; p += 1
        if nfx:
            p += 1 + nfx * 7
        parent = self.parents().get(oid)
        for skip in (1, 0):
            q = p + skip + 4
            if q + 6 > o + sz:
                continue
            if struct.unpack_from('<I', b, q)[0] == (parent or 0):
                q += 4 + 1
                n = b[q]; q += 1
                ids = list(b[q:q + n]); q += n
                return {i: struct.unpack_from('<f', b, q + 4 * k)[0] for k, i in enumerate(ids)}
        return {}

    def chain_props(self, oid):
        """volume (dB) and pitch (cents) summed over the node and all its ancestors"""
        vol = pitch = 0.0
        n, seen = oid, 0
        while n and seen < 32:
            pr = self.props(n)
            vol += pr.get(PROP_VOLUME, 0.0); pitch += pr.get(PROP_PITCH, 0.0)
            n = self.parents().get(n); seen += 1
        return vol, pitch

    def clips(self, node):
        """[(wem, volume dB, pitch cents, loop)] of every sound under node.
        loop is the Sound's Loop property (58): None = plays once, 0 = loops
        until stopped, n = n plays. Wwise loops between the wem's own loop
        points; a wem with loop points but no Loop property plays once."""
        t = self.objects[node][0]
        if t == HIRC_SOUND:
            v, c = self.chain_props(node)
            loop = self.props(node).get(PROP_LOOP)
            return [(self.sound_source(node)[2], v, c, None if loop is None else int(round(loop)))]
        out = []
        for k in self.children(node):
            out += self.clips(k)
        return out

    def layers_detail(self, node):
        """like layers() but every alternative carries (wem, dB, cents, loop)"""
        t = self.objects[node][0]
        if t == HIRC_SOUND:
            return [self.clips(node)]
        kids = self.children(node)
        if t == 9:
            out = []
            for k in kids:
                out += self.layers_detail(k) if self.objects[k][0] == 9 else [self.clips(k)]
            return out
        if len(kids) == 1:
            return self.layers_detail(kids[0])
        return [self.clips(node)]

    def event_layers_detail(self, eid):
        out = []
        for aid in self.event_actions(eid):
            atype, target = self.action(aid)
            if (atype >> 8) == 0x04 and target in self.objects:
                out += self.layers_detail(target)
        return out

    def children(self, node):
        par = self.parents()
        return sorted(k for k, p in par.items() if p == node)

    def all_wems(self, node):
        t = self.objects[node][0]
        if t == HIRC_SOUND:
            return [self.sound_source(node)[2]]
        out = []
        for k in self.children(node):
            out += self.all_wems(k)
        return out

    def layers(self, node):
        """Play structure of a node: list of layers played together, each a list
        of alternatives picked at random (random containers, layer containers)."""
        t = self.objects[node][0]
        if t == HIRC_SOUND:
            return [[self.sound_source(node)[2]]]
        kids = self.children(node)
        if t == 9:  # layer container: every child sounds at once
            out = []
            for k in kids:
                kt = self.objects[k][0]
                out += self.layers(k) if kt == 9 else [self.all_wems(k)]
            return out
        if len(kids) == 1:
            return self.layers(kids[0])
        return [self.all_wems(node)]

    def event_layers(self, eid):
        out = []
        for aid in self.event_actions(eid):
            atype, target = self.action(aid)
            if (atype >> 8) == 0x04 and target in self.objects:
                out += self.layers(target)
        return out

    def event_media(self, eid):
        rows = []
        for aid in self.event_actions(eid):
            atype, target = self.action(aid)
            if (atype >> 8) != 0x04:  # 0x04xx = Play
                continue
            targets = [target] if self.objects.get(target, (None,))[0] == HIRC_SOUND else self.sounds_under(target)
            for sid in targets:
                plugin, stream, wem, mem = self.sound_source(sid)
                rows.append({'sound': sid, 'wem': wem, 'stream': stream, 'plugin': hex(plugin), 'embedded': wem in self.didx,
                             'target': target, 'targetType': self.objects.get(target, (None,))[0]})
        return rows


if __name__ == '__main__':
    bank = Bank(sys.argv[1])
    events = {oid for oid, (t, _, _) in bank.objects.items() if t == HIRC_EVENT}
    print('bank version', bank.version, 'events', len(events), 'embedded media', len(bank.didx))
    for name in sys.argv[2:]:
        h = fnv1(name)
        if h in events:
            print(name, 'FOUND', h, json.dumps(bank.event_media(h)))
        else:
            print(name, 'no event', h)
