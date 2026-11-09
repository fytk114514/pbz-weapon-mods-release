"""Reader for Bloodborne effect files (FXR version 2, 64-bit, little endian).

The format is Dark Souls 1's FXR (SoulsFormats' FXR1) with these differences, found by checking every read against
the file's own relocation tables (header: offset of the tables, number of pointer fields, number of nodes):
  * root node 133 is 96 bytes: 133, effect id, 0, 0, 96, container, states pointer, state count, node pointer
  * a container is 32 bytes: node table pointer, int32 node count, int32 second count, 4 flag bytes, 4 bytes
    garbage, modifier pointer (DS1R also had an action-data pointer; Bloodborne passes everything as nodes)
  * new node types: 40 texture id, 82 (node, float), 83 random colour (two RGBA), 141/142/143/146/147
    (int, inline container)
A varint is an int32 followed by 4 bytes of 0 (or 0xCDCDCDCD).  Every pointer that is read must be listed in the
pointer table and every node must be listed in the node table, so an unknown layout shows up as an error or as
unread table entries instead of silently wrong values.

Usage: bbfxr.py <fxr> [--json out.json] [--quiet]"""
import json, struct, sys

SEQ = {3: 'i', 5: 'i', 6: 'i', 9: 'i', 11: 'f', 12: 'f', 13: 'f3', 14: 'f3', 19: 'c', 20: 'c', 21: 'c2', 22: 'c2',
       27: 'c', 28: 'c', 29: 'c2'}
SCALAR = {1: 'int', 7: 'float', 40: 'texture', 41: 'int41', 68: 'sound68', 69: 'sound69', 70: 'tick',
          111: 'int111'}
INDEXED = {44, 45, 46, 47, 59, 60, 66, 71, 114, 115}
PAIR = {79: 'i2', 81: 'f2', 85: 'tick2'}
WRAP = {141, 142, 143, 146, 147}
EMPTY = {112, 113, 129, 130, 131, 132, 136}
MOD_SIZE = {0: 8, 1: 48, 2: 24, 3: 20, 4: 8, 5: 8, 6: 12, 7: 8}


class FXRError(Exception):
    pass


class BBFXR:
    def __init__(self, path):
        self.path = path
        b = self.b = open(path, 'rb').read()
        if b[:4] != b'FXR\0':
            raise FXRError('not an FXR')
        self.version = struct.unpack_from('<I', b, 4)[0]
        meta, nptr, nnode, self.unk1, self.unk2 = struct.unpack_from('<iiiii', b, 0x10)
        self.meta = meta
        self.ptrs = [struct.unpack_from('<q', b, meta + 8 * i)[0] for i in range(nptr)]
        self.nodeset = set(struct.unpack_from('<q', b, meta + 8 * nptr + 8 * i)[0] for i in range(nnode))
        self.ptrset = set(self.ptrs)
        self.used_ptrs = set()
        self.seen_nodes = {}
        self.containers = {}
        self.states = {}
        self.warnings = []
        self.root = self.read_root(struct.unpack_from('<q', b, 8)[0])

    # --- primitives -------------------------------------------------------------------------------
    def i32(self, o):
        return struct.unpack_from('<i', self.b, o)[0]

    def f32(self, o):
        return struct.unpack_from('<f', self.b, o)[0]

    def var(self, o):
        g = struct.unpack_from('<I', self.b, o + 4)[0]
        if g not in (0, 0xCDCDCDCD):
            raise FXRError('varint garbage 0x%X at 0x%X' % (g, o))
        return self.i32(o)

    def ptr(self, o):
        v = self.var(o)
        if v == 0:
            if o in self.ptrset:
                self.used_ptrs.add(o)
            return 0
        if o not in self.ptrset:
            raise FXRError('field at 0x%X (value 0x%X) is not in the pointer table' % (o, v))
        self.used_ptrs.add(o)
        return v

    # --- structures -------------------------------------------------------------------------------
    def read_root(self, o):
        if self.var(o) != 133:
            raise FXRError('root is not node 133')
        r = {'type': 133, 'at': o, 'effect_id': self.var(o + 8),
             'unk': [self.var(o + 16), self.var(o + 24), self.var(o + 32)],
             'container': self.container_inline(o + 40)}
        sp, n = self.ptr(o + 72), self.var(o + 80)
        self.nodeset_check(o)
        self.seen_nodes[o] = r
        r['states'] = [self.state(sp + 24 * i) for i in range(n)]
        r['extra'] = self.node(self.ptr(o + 88))
        return r

    def nodeset_check(self, o):
        if o not in self.nodeset:
            self.warnings.append('node at 0x%X is not in the node table' % o)

    def container_inline(self, o):
        if o in self.containers:
            return {'ref': o}
        table, n1, n2 = self.ptr(o), self.i32(o + 8), self.i32(o + 12)
        flags = list(self.b[o + 16:o + 20])
        garb = self.i32(o + 20)
        mod = self.ptr(o + 24)
        c = {'at': o, 'n2': n2, 'flags': flags}
        if garb:
            c['garbage'] = garb
        self.containers[o] = c
        c['nodes'] = [self.node(self.ptr(table + 8 * i)) for i in range(n1)]
        if mod:
            c['modifier'] = self.modifier(mod)
        return c

    def modifier(self, o):
        t = self.i32(o)
        size = MOD_SIZE.get(t)
        if size is None:
            self.warnings.append('unknown modifier %d at 0x%X' % (t, o))
            size = 48
        raw = self.b[o + 4:o + size]
        return {'type': t, 'at': o, 'ints': list(struct.unpack('<%di' % (len(raw) // 4), raw)),
                'floats': [round(x, 5) for x in struct.unpack('<%df' % (len(raw) // 4), raw)]}

    def state(self, o):
        if o in self.states:
            return {'state_ref': o}
        tp, ap, nt, na = self.ptr(o), self.ptr(o + 8), self.i32(o + 16), self.i32(o + 20)
        s = {'at': o}
        self.states[o] = s
        s['transitions'] = [{'target': self.ptr(tp + 16 * i), 'when': self.node(self.ptr(tp + 16 * i + 8))}
                            for i in range(nt)]
        s['actions'] = [{'action': self.var(ap + 40 * i), 'container': self.container_inline(ap + 40 * i + 8)}
                        for i in range(na)]
        for t in s['transitions']:
            if t['target'] not in self.states:
                self.state(t['target'])
        return s

    def seq(self, o, kind):
        tp, vp, n = self.ptr(o + 8), self.ptr(o + 16), self.var(o + 24)
        times = [round(self.f32(tp + 4 * i), 5) for i in range(n)]
        # Curves (13/14 float, 21/22/29 colour) store all key values first and then two tangent blocks
        # (angles; 0.7854 = 45 degrees); only the values are kept here.
        width = {'i': 1, 'f': 1, 'f3': 1, 'c': 4, 'c2': 4}[kind]
        if kind == 'i':
            vals = [self.i32(vp + 4 * i) for i in range(n)]
        else:
            vals = [[round(self.f32(vp + 4 * (i * width + k)), 5) for k in range(width)] for i in range(n)]
            if width == 1:
                vals = [v[0] for v in vals]
        return list(zip(times, vals))

    def node(self, o):
        if o == 0:
            return None
        if o in self.seen_nodes:
            return {'ref': o, 'type': self.seen_nodes[o].get('type')}
        self.nodeset_check(o)
        t = self.var(o)
        n = {'type': t, 'at': o}
        self.seen_nodes[o] = n
        if t in SCALAR:
            n['kind'] = SCALAR[t]
            n['value'] = round(self.f32(o + 8), 6) if t in (7, 70) else self.var(o + 8)
        elif t == 2:
            lp, cnt = self.ptr(o + 8), self.var(o + 16)
            n['values'] = [self.i32(lp + 4 * i) for i in range(cnt)]
        elif t in SEQ:
            n['kind'] = 'seq_' + SEQ[t]
            n['keys'] = self.seq(o, SEQ[t])
        elif t in INDEXED:
            n['kind'] = 'indexed'
            n['index'] = list(struct.unpack_from('<hh', self.b, o + 8))
        elif t in PAIR:
            n['kind'] = PAIR[t]
            n['value'] = [self.i32(o + 8), self.i32(o + 12)] if t == 79 else \
                [round(self.f32(o + 8), 6), round(self.f32(o + 12), 6)]
        elif t == 37:
            n['kind'] = 'effect_call'
            n['effect_id'] = self.var(o + 8)
            c = self.ptr(o + 16)
            n['unk'] = self.var(o + 24)
            n['container'] = self.container_inline(c) if c else None
        elif t == 38:
            n['kind'] = 'action_call'
            n['action'] = self.var(o + 8)
            c = self.ptr(o + 16)
            n['unk'] = self.var(o + 24)
            n['container'] = self.container_inline(c) if c else None
        elif t == 82:
            n['kind'] = 'node_float'
            n['node'] = self.node(self.ptr(o + 8))
            n['value'] = round(self.f32(o + 16), 6)
        elif t == 83:
            n['kind'] = 'random_color'
            n['flag'] = self.var(o + 8)
            n['min'] = [round(self.f32(o + 16 + 4 * k), 5) for k in range(4)]
            n['max'] = [round(self.f32(o + 32 + 4 * k), 5) for k in range(4)]
        elif t in WRAP:
            n['kind'] = 'wrap'
            n['param'] = self.var(o + 8)
            n['container'] = self.container_inline(o + 16)
        elif t in EMPTY:
            n['kind'] = 'empty'
        elif t in (120, 121, 122, 123, 124, 126, 127):
            n['kind'] = 'node2'
            n['nodes'] = [self.node(self.ptr(o + 8)), self.node(self.ptr(o + 16))]
        elif t == 128:
            n['kind'] = 'node1'
            n['nodes'] = [self.node(self.ptr(o + 8))]
        else:
            n['kind'] = 'UNKNOWN'
            n['raw'] = ['0x%X' % self.i32(o + 8 * k) for k in range(1, 6)]
            self.warnings.append('unknown node type %d at 0x%X' % (t, o))
        return n

    def report(self):
        unused = sorted(set(self.ptrs) - self.used_ptrs)
        unseen = sorted(self.nodeset - set(self.seen_nodes))
        return {'pointers': len(self.ptrs), 'pointers_unread': len(unused), 'nodes': len(self.nodeset),
                'nodes_unread': len(unseen), 'first_unread_pointers': ['0x%X' % p for p in unused[:12]],
                'first_unread_nodes': ['0x%X' % p for p in unseen[:12]], 'warnings': self.warnings[:20]}


def short(n):
    """One-line description of a leaf node."""
    if n is None:
        return 'null'
    if 'ref' in n:
        return '@0x%X(t%s)' % (n['ref'], n.get('type'))
    k = n.get('kind')
    t = n['type']
    if k in ('int', 'float', 'texture', 'int41', 'sound68', 'sound69', 'tick', 'int111'):
        return '%s=%s' % (k, n['value'])
    if k and k.startswith('seq_'):
        keys = n['keys']
        txt = ', '.join('%g:%s' % (tm, v) for tm, v in keys[:6])
        return 'seq%d[%s%s]' % (t, txt, ' ...' if len(keys) > 6 else '')
    if k in ('i2', 'f2', 'tick2'):
        return '%s=%s' % (k, n['value'])
    if k == 'indexed':
        return 'idx%d%s' % (t, n['index'])
    if k == 'random_color':
        return 'rand_color(%s..%s, %d)' % (n['min'], n['max'], n['flag'])
    if k == 'empty':
        return 'empty%d' % t
    if t == 2:
        return 'ints%s' % n['values']
    return None


def dump(n, depth=0, out=None, label=''):
    pad = '  ' * depth
    s = short(n)
    if s is not None:
        out.append('%s%s%s' % (pad, label, s))
        return
    k = n.get('kind')
    if k in ('effect_call', 'action_call'):
        what = 'effect %d' % n['effect_id'] if k == 'effect_call' else 'action %d' % n['action']
        out.append('%s%s[%s @0x%X unk=%d]' % (pad, label, what, n['at'], n['unk']))
        if n['container']:
            dump_container(n['container'], depth + 1, out)
    elif k == 'node_float':
        out.append('%s%snode82(%g) @0x%X' % (pad, label, n['value'], n['at']))
        dump(n['node'], depth + 1, out)
    elif k == 'wrap':
        out.append('%s%snode%d(param=%d) @0x%X' % (pad, label, n['type'], n['param'], n['at']))
        dump_container(n['container'], depth + 1, out)
    elif k in ('node1', 'node2'):
        out.append('%s%snode%d @0x%X' % (pad, label, n['type'], n['at']))
        for c in n['nodes']:
            dump(c, depth + 1, out)
    else:
        out.append('%s%s%s' % (pad, label, json.dumps(n)[:200]))


def dump_container(c, depth, out):
    pad = '  ' * depth
    if 'ref' in c:
        out.append('%s(container @0x%X again)' % (pad, c['ref']))
        return
    extra = ' n2=%d' % c['n2'] if c['n2'] != len(c['nodes']) else ''
    flags = ' flags=%s' % c['flags'] if any(c['flags']) else ''
    mod = ' modifier %d %s' % (c['modifier']['type'], c['modifier']['floats']) if 'modifier' in c else ''
    out.append('%s<container @0x%X, %d nodes%s%s%s>' % (pad, c['at'], len(c['nodes']), extra, flags, mod))
    for i, n in enumerate(c['nodes']):
        dump(n, depth + 1, out, '%d: ' % i)


def main():
    fx = BBFXR(sys.argv[1])
    out = []
    r = fx.root
    out.append('effect %d  (root unk %s) %s' % (r['effect_id'], r['unk'], fx.path))
    dump_container(r['container'], 1, out)
    for s in fx.states.values():
        out.append('  STATE @0x%X' % s['at'])
        for t in s['transitions']:
            out.append('    -> state @0x%X when %s' % (t['target'], short(t['when']) or t['when'].get('kind')))
        for a in s['actions']:
            out.append('    ACTION %d' % a['action'])
            dump_container(a['container'], 3, out)
    out.append('  EXTRA:')
    dump(r['extra'], 2, out)
    rep = fx.report()
    out.append('REPORT %s' % json.dumps(rep))
    if '--quiet' not in sys.argv:
        print('\n'.join(out))
    else:
        print(out[-1])
    if '--json' in sys.argv:
        json.dump({'root': r, 'report': rep}, open(sys.argv[sys.argv.index('--json') + 1], 'w'), indent=1)


if __name__ == '__main__':
    main()
