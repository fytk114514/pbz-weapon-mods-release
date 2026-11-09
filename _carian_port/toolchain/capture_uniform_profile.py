"""Capture PBZ's shader uniform-buffer layouts from the running game (read only).

Same method as read_crash_uniform_layout.py --profile-only (v1.3): the renderer
metadata named below is found in the executable's static data, FSceneUniform-
Parameters (built on the heap at renderer start-up) by walking only the
FShaderParametersMetadata registry from a verified root. The process is opened
with PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_VM_READ: nothing is written,
nothing is injected, no unrelated memory is read.

Unlike the v1.3 script this writes to a directory of its own, so the profile in
use (unreal_port/Config/PBZUniformProfile.json) is never overwritten by accident,
and it records the game build and executable hash.

Usage (game running, title screen is enough):
  python capture_uniform_profile.py <out_dir> <build label, e.g. 5.7.4-302256>
Writes <out_dir>/PBZUniformProfile.json, game_uniform_layouts.json,
renderer_metadata_registry.json.
"""
from pathlib import Path
import ctypes as C, hashlib, json, struct, subprocess, sys
import pefile

out = Path(sys.argv[1])
label = sys.argv[2]
out.mkdir(parents=True, exist_ok=True)
expected = r'<影之刃零安装目录>\platform\steam\PBZ.exe'
cmd = "Get-CimInstance Win32_Process -Filter \"Name='PBZ.exe'\" | Select-Object ProcessId,ExecutablePath | ConvertTo-Json -Compress"
processes = json.loads(subprocess.check_output(['powershell', '-NoProfile', '-Command', cmd], text=True, encoding='utf-8'))
if isinstance(processes, dict):
    processes = [processes]
matches = [x for x in processes if (x.get('ExecutablePath') or '').lower() == expected.lower()]
assert len(matches) == 1, matches
pid = matches[0]['ProcessId']
k = C.WinDLL('kernel32', use_last_error=True)
k.OpenProcess.argtypes = [C.c_uint, C.c_bool, C.c_uint]; k.OpenProcess.restype = C.c_void_p
k.ReadProcessMemory.argtypes = [C.c_void_p, C.c_void_p, C.c_void_p, C.c_size_t, C.POINTER(C.c_size_t)]; k.ReadProcessMemory.restype = C.c_bool
k.CloseHandle.argtypes = [C.c_void_p]
h = k.OpenProcess(0x1010, False, pid)
assert h, C.get_last_error()


def read(a, n):
    b = C.create_string_buffer(n); size = C.c_size_t()
    assert k.ReadProcessMemory(h, a, b, n, C.byref(size)) and size.value == n, (hex(a), n, C.get_last_error())
    return b.raw


def q(a):
    return struct.unpack('<Q', read(a, 8))[0]


def array(a, size):
    pointer, count, capacity = struct.unpack('<QII', read(a, 16))
    assert count <= 1024 and count <= capacity, (pointer, count, capacity)
    return read(pointer, count * size) if count else b''


try:
    pe = pefile.PE(expected, fast_load=True)
    image_base = int(subprocess.check_output(['powershell', '-NoProfile', '-Command', f'(Get-Process -Id {pid}).MainModule.BaseAddress.ToInt64()'], text=True).strip())
    image = Path(expected).read_bytes()
    sections = []
    for section in pe.sections:
        if (section.Characteristics & 0x80000000) and not (section.Characteristics & 0x20000000):
            assert section.Misc_VirtualSize < 128 * 1024 * 1024
            sections.append((image_base + section.VirtualAddress, read(image_base + section.VirtualAddress, section.Misc_VirtualSize)))
    layouts, metadata_records, profile_roots = [], {}, []

    def text16(pointer):
        if not pointer:
            return None
        chars = []
        for i in range(0, 1024, 2):
            pair = read(pointer + i, 2)
            if pair == b'\0\0':
                return b''.join(chars).decode('utf-16-le')
            chars.append(pair)
        raise ValueError('Unexpectedly long metadata name')

    def capture_metadata(address):
        key = hex(address)
        if key in metadata_records:
            return key
        b = read(address, 0x60)
        layout_name, type_name, shader_name, static_name = struct.unpack_from('<QQQQ', b, 8)
        size = struct.unpack_from('<I', b, 0x3c)[0]
        members_ptr, count, capacity = struct.unpack_from('<QII', b, 0x50)
        assert count <= 1024 and count <= capacity and size <= 65536
        result = {'layout_name': text16(layout_name), 'type': text16(type_name), 'shader_name': text16(shader_name),
                  'static_slot': text16(static_name), 'size': size, 'use_case': b[0x40],
                  'binding_flags': b[0x41], 'usage_flags': b[0x42], 'members': []}
        metadata_records[key] = result
        members = read(members_ptr, count * 0x30) if count else b''
        for i in range(count):
            m = members[i * 0x30:(i + 1) * 0x30]
            name, shader_type = struct.unpack_from('<QQ', m)
            line, offset = struct.unpack_from('<II', m, 0x10)
            rows, columns, elements = struct.unpack_from('<III', m, 0x1c)
            nested = struct.unpack_from('<Q', m, 0x28)[0]
            result['members'].append({'name': text16(name), 'shader_type': text16(shader_type),
                                      'line': line, 'offset': offset, 'base_type': m[0x18], 'precision': m[0x19],
                                      'rows': rows, 'columns': columns, 'elements': elements,
                                      'struct': capture_metadata(nested) if nested else None})
        return key

    # the same list as the v1.3 capture (FSceneUniformParameters is only found by the registry walk below)
    for type_name in ('FViewUniformShaderParameters', 'FInstancedViewUniformShaderParameters', 'FOpaqueBasePassUniformParameters',
                      'FTranslucentBasePassUniformParameters', 'FShadowDepthPassUniformParameters', 'FDistortionPassUniformParameters',
                      'FSceneTextureUniformParameters', 'FNiagaraSpriteVFLooseParameters', 'FNiagaraSpriteUniformParameters',
                      'FLocalVertexFactoryUniformShaderParameters', 'FSceneUniformParameters'):
        pattern = (type_name + '\0').encode('utf-16-le'); start = 0
        while (offset := image.find(pattern, start)) >= 0:
            start = offset + 1
            try:
                name_address = image_base + pe.get_rva_from_offset(offset)
            except Exception:
                continue
            signature = struct.pack('<Q', name_address) * 2
            for section_address, section_data in sections:
                pos = 0
                while (pos := section_data.find(signature, pos)) >= 0:
                    metadata = section_address + pos - 8; pos += 1
                    try:
                        layout = q(metadata + 0x48)
                        resource_bytes = array(layout + 0x20, 4)
                        layout_name = array(layout + 0x10, 2).decode('utf-16-le').rstrip('\0')
                        hash_value, size = struct.unpack('<II', read(layout + 0x80, 8))
                        layouts.append({'name': layout_name, 'type': type_name, 'hash': hex(hash_value), 'constant_bytes': size,
                                        'resources': [{'offset': struct.unpack_from('<H', resource_bytes, i)[0], 'type': resource_bytes[i + 2]}
                                                      for i in range(0, len(resource_bytes), 4)]})
                        profile_roots.append({'id': capture_metadata(metadata), 'expected_hash': hex(hash_value),
                                              'expected_resources': layouts[-1]['resources']})
                    except (AssertionError, ValueError, UnicodeError):
                        continue
    wanted = {'FSceneUniformParameters'}
    pending = [int(profile_roots[0]['id'], 16) + 0x60]
    seen, registry = set(), []
    while pending and len(seen) < 4096:
        link = pending.pop()
        if link in seen or not link:
            continue
        seen.add(link)
        try:
            following, previous, address = struct.unpack('<QQQ', read(link, 24))
            if address + 0x60 != link:
                continue
            type_name = text16(q(address + 0x10))
            registry.append(type_name)
            pending.extend([following, previous])
            if type_name not in wanted:
                continue
            wanted.remove(type_name)
            layout = q(address + 0x48); resource_bytes = array(layout + 0x20, 4)
            hash_value, size = struct.unpack('<II', read(layout + 0x80, 8))
            entry = {'name': array(layout + 0x10, 2).decode('utf-16-le').rstrip('\0'), 'type': type_name, 'hash': hex(hash_value), 'constant_bytes': size,
                     'resources': [{'offset': struct.unpack_from('<H', resource_bytes, i)[0], 'type': resource_bytes[i + 2]} for i in range(0, len(resource_bytes), 4)]}
            layouts.append(entry)
            profile_roots.append({'id': capture_metadata(address), 'expected_hash': hex(hash_value), 'expected_resources': entry['resources']})
        except (AssertionError, ValueError, UnicodeError):
            continue
    assert not wanted, 'Missing dynamic renderer metadata: ' + repr(wanted)
    (out / 'renderer_metadata_registry.json').write_text(json.dumps({'visited': len(registry), 'names': registry}, indent=2), encoding='utf-8')
    (out / 'game_uniform_layouts.json').write_text(json.dumps(layouts, indent=2), encoding='utf-8')
    profile = {'format': 'CBA_GameUniformProfile/1', 'game_engine': label,
               'purpose': 'Headless shader compilation metadata only; does not change the game or engine files.',
               'roots': profile_roots, 'metadata': metadata_records,
               'provenance': {'target_build': label, 'executable_sha256': hashlib.sha256(image).hexdigest(),
                              'captured_by': 'bounded read-only FShaderParametersMetadata registry traversal (capture_uniform_profile.py)',
                              'root_count': len(profile_roots)}}
    (out / 'PBZUniformProfile.json').write_text(json.dumps(profile, indent=2), encoding='utf-8')
    print(json.dumps([{k2: v for k2, v in x.items() if k2 != 'resources'} for x in layouts], indent=1))
finally:
    k.CloseHandle(h)
