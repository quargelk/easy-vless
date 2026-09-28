#!/usr/bin/env python3
# Easy VLESS - PO to LMO compiler for the LuCI translation catalogs.
#
#   python3 scripts/po2lmo.py input.po output.lmo
#
# A line-by-line port of LuCI's own po2lmo tool
# (openwrt/luci modules/luci-base/src/po2lmo.c and src/lib/lmo.c, branch
# openwrt-24.10): same PO parsing, same SuperFastHash keys, same file layout
# (translations padded to 4 bytes, big-endian index sorted by key, index
# offset last). The output is byte-identical to po2lmo's; the package build
# uses this script because the SDK build of luci-app-easy-vless is a plain
# package.mk build without the luci-base host tools.
#
# Only the stdlib is used (the OpenWrt build system already requires python3).

import struct
import sys


def sfh_hash(data, init):
	"""Paul Hsieh's SuperFastHash as in lmo.c (signed char tail bytes)."""
	M = 0xFFFFFFFF
	if not data:
		return 0
	h = init & M
	rem = len(data) & 3
	off = 0
	for _ in range(len(data) >> 2):
		h = (h + (data[off] | data[off + 1] << 8)) & M
		tmp = (((data[off + 2] | data[off + 3] << 8) << 11) ^ h) & M
		h = ((h << 16) ^ tmp) & M
		off += 4
		h = (h + (h >> 11)) & M
	sc = lambda b: b - 256 if b > 127 else b
	if rem == 3:
		h = (h + (data[off] | data[off + 1] << 8)) & M
		h ^= (h << 16) & M
		h ^= (sc(data[off + 2]) << 18) & M
		h = (h + (h >> 11)) & M
	elif rem == 2:
		h = (h + (data[off] | data[off + 1] << 8)) & M
		h ^= (h << 11) & M
		h = (h + (h >> 17)) & M
	elif rem == 1:
		h = (h + sc(data[off])) & M
		h ^= (h << 10) & M
		h = (h + (h >> 1)) & M
	h ^= (h << 3) & M
	h = (h + (h >> 5)) & M
	h ^= (h << 4) & M
	h = (h + (h >> 17)) & M
	h ^= (h << 25) & M
	h = (h + (h >> 6)) & M
	return h


def extract_string(src):
	"""The quoted string of a PO line; '\\"' and '\\\\' are unescaped, every
	other escape (e.g. '\\n') is kept as written, like po2lmo does."""
	if src[:1] == b'#':
		return None
	start = src.find(b'"')
	if start < 0:
		return None
	out = bytearray()
	esc = False
	for b in src[start + 1:]:
		if esc:
			if b in b'"\\':
				out[-1] = b
			else:
				out.append(b)
			esc = False
		elif b == 0x5C:
			out.append(b)
			esc = True
		elif b != 0x22:
			out.append(b)
		else:
			break
	return bytes(out)


class Compiler:
	def __init__(self):
		self.entries = []   # (key_id, val_id, offset, length)
		self.data = bytearray()

	def add(self, key_id, val_id, val):
		self.entries.append((key_id, val_id, len(self.data), len(val)))
		self.data += val + b'\0' * ((4 - len(val) % 4) % 4)

	def msg(self, m):
		if m['id'] and m['val'][0]:
			for i in range(m['plural'] + 1):
				val = m['val'][i]
				if not val:
					continue
				if m['ctxt'] and m['id_plural']:
					key = m['ctxt'] + b'\1' + m['id'] + b'\2' + str(i).encode()
				elif m['ctxt']:
					key = m['ctxt'] + b'\1' + m['id']
				elif m['id_plural']:
					key = m['id'] + b'\2' + str(i).encode()
				else:
					key = m['id']
				key_id = sfh_hash(key, len(key))
				if key_id != sfh_hash(val, len(val)):
					self.add(key_id, m['plural'] + 1, val)
		elif m['val'][0]:
			for field in m['val'][0].split(b'\\n'):
				if field[:14].lower() == b'plural-forms: ':
					self.add(0, 0, field[14:])
					break

	def output(self):
		index = b''.join(struct.pack('>IIII', *e)
		                 for e in sorted(self.entries, key=lambda e: e[0]))
		return bytes(self.data) + index + struct.pack('>I', len(self.data))


def new_msg():
	return {'ctxt': None, 'id': None, 'id_plural': None, 'val': [None] * 10, 'plural': -1}


def compile_po(lines):
	c = Compiler()
	m = new_msg()
	cur = None
	for line in lines + [None]:
		if line is not None and line.startswith(b'msgctxt "'):
			if m['id'] or m['val'][0]:
				c.msg(m)
				m = new_msg()
			cur = ('ctxt', None)
			m['ctxt'] = None
		elif line is None or line.startswith(b'msgid "'):
			if m['id'] or m['val'][0]:
				c.msg(m)
				m = new_msg()
			cur = ('id', None)
			m['id'] = None
		elif line.startswith(b'msgid_plural "'):
			cur = ('id_plural', None)
			m['id_plural'] = None
		elif line.startswith(b'msgstr "') or line.startswith(b'msgstr['):
			n = int(line[7:].split(b']')[0]) if line[6:7] == b'[' else 0
			if n >= 10:
				sys.exit('Error: Too many plural forms')
			m['plural'] = n
			m['val'][n] = None
			cur = ('val', n)
		if line is None:
			break
		if cur:
			s = extract_string(line)
			if s:
				if cur[0] == 'val':
					m['val'][cur[1]] = (m['val'][cur[1]] or b'') + s
				else:
					m[cur[0]] = (m[cur[0]] or b'') + s
	return c


def main():
	if len(sys.argv) != 3:
		sys.exit('Usage: %s input.po output.lmo' % sys.argv[0])
	with open(sys.argv[1], 'rb') as f:
		lines = f.read().splitlines(keepends=True)
	for n, line in enumerate(lines, 1):
		if len(line) >= 4095:
			sys.exit('Error: %s:%d: line too long for po2lmo' % (sys.argv[1], n))
	c = compile_po(lines)
	if not c.data:
		sys.exit('Error: %s: no translations' % sys.argv[1])
	with open(sys.argv[2], 'wb') as f:
		f.write(c.output())


if __name__ == '__main__':
	main()
