#!/usr/bin/env python3
# Easy VLESS - translation catalog maintenance for luci-app-easy-vless.
#
#   python3 scripts/i18n-sync.py           regenerate luci/po/templates/easy-vless.pot
#                                          and merge it into every luci/po/<lang>/easy-vless.po
#                                          (new strings get an empty msgstr, removed ones are dropped)
#   python3 scripts/i18n-sync.py --check   verify only (static checks / CI): the template is
#                                          current and every catalog translates every string with
#                                          the same placeholders and HTML tags
#
# Strings are the literal arguments of _() in the LuCI JavaScript views and
# the menu titles of menu.d. Whitespace is canonicalized exactly like LuCI
# does at lookup time (cbi.js trimws / lmo_canon_hash): trimmed, runs of
# whitespace -> one space.

import glob
import io
import json
import os
import re
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
PO_DIR = os.path.join(ROOT, 'luci', 'po')
POT = os.path.join(PO_DIR, 'templates', 'easy-vless.pot')
JS_GLOB = os.path.join(ROOT, 'luci', 'htdocs', '**', '*.js')
MENU_GLOB = os.path.join(ROOT, 'luci', 'root', 'usr', 'share', 'luci', 'menu.d', '*.json')

ESC = {'n': '\n', 't': '\t', 'r': '\r', 'b': '\b', 'f': '\f', 'v': '\v', '0': '\0'}


def canon(s):
	return re.sub(r'\s+', ' ', s).strip()


def js_string(src, i):
	"""Parse the JS string literal starting at src[i]; returns (value, end)."""
	q = src[i]
	out = []
	i += 1
	while i < len(src):
		c = src[i]
		if c == '\\':
			n = src[i + 1]
			if n == 'u':
				out.append(chr(int(src[i + 2:i + 6], 16)))
				i += 6
			elif n == 'x':
				out.append(chr(int(src[i + 2:i + 4], 16)))
				i += 4
			elif n == '\n':
				i += 2
			else:
				out.append(ESC.get(n, n))
				i += 2
			continue
		if c == q:
			return ''.join(out), i + 1
		if q == '`' and c == '$' and src[i + 1:i + 2] == '{':
			raise ValueError('template literal with ${} in _()')
		if c == '\n' and q != '`':
			raise ValueError('unterminated string')
		out.append(c)
		i += 1
	raise ValueError('unterminated string')


def scan():
	"""msgid -> list of 'file:line' references, in order of appearance."""
	found = {}
	errors = []
	for path in sorted(glob.glob(JS_GLOB, recursive=True)):
		rel = os.path.relpath(path, ROOT).replace(os.sep, '/')
		src = io.open(path, encoding='utf-8').read().replace('\r\n', '\n')
		for m in re.finditer(r'(?<![\w$.])_\(\s*', src):
			i = m.end()
			line = src.count('\n', 0, m.start()) + 1
			if src[i] not in '\'"`':
				errors.append('%s:%d: _() without a string literal' % (rel, line))
				continue
			try:
				s, j = js_string(src, i)
			except ValueError as e:
				errors.append('%s:%d: %s' % (rel, line, e))
				continue
			rest = src[j:].lstrip()
			if rest[:1] == '+':
				errors.append('%s:%d: concatenated string in _()' % (rel, line))
			s = canon(s)
			if s:
				refs = found.setdefault(s, [])
				if rel not in refs:
					refs.append(rel)
	for path in sorted(glob.glob(MENU_GLOB)):
		rel = os.path.relpath(path, ROOT).replace(os.sep, '/')
		for node in json.load(io.open(path, encoding='utf-8')).values():
			if node.get('title'):
				refs = found.setdefault(canon(node['title']), [])
				if rel not in refs:
					refs.append(rel)
	return found, errors


def po_quote(s):
	return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'


def po_unquote(s):
	s = s.strip()
	assert s[0] == '"' and s[-1] == '"', s
	return re.sub(r'\\(.)', lambda m: {'n': '\n', 't': '\t'}.get(m.group(1), m.group(1)), s[1:-1])


def read_po(path):
	"""[(msgid, msgstr, fuzzy)] of a PO file (header included as msgid '')."""
	entries = []
	cur = None
	field = None
	fuzzy = False
	for line in io.open(path, encoding='utf-8').read().splitlines():
		if line.startswith('#,') and 'fuzzy' in line:
			fuzzy = True
		elif line.startswith('msgid '):
			if cur:
				entries.append(cur)
			cur = {'id': po_unquote(line[6:]), 'str': '', 'fuzzy': fuzzy}
			fuzzy = False
			field = 'id'
		elif line.startswith('msgstr '):
			cur['str'] = po_unquote(line[7:])
			field = 'str'
		elif line.startswith('"') and cur:
			cur[field] += po_unquote(line)
		elif line.startswith('msgctxt') or line.startswith('msgid_plural') or line.startswith('msgstr['):
			raise SystemExit('%s: msgctxt/plural forms are not used by this project' % path)
	if cur:
		entries.append(cur)
	return entries


HEADER = ('msgid ""\nmsgstr ""\n"Content-Type: text/plain; charset=UTF-8\\n"\n'
          '"Project-Id-Version: luci-app-easy-vless\\n"\n')


def render_pot(found):
	out = [HEADER]
	for s, refs in found.items():
		out.append('\n#: %s\nmsgid %s\nmsgstr ""\n' % (' '.join(refs), po_quote(s)))
	return ''.join(out)


def render_po(found, lang, old):
	out = [HEADER.rstrip('\n') + '\n"Language: %s\\n"\n' % lang]
	for s, refs in found.items():
		out.append('\n#: %s\nmsgid %s\nmsgstr %s\n' % (' '.join(refs), po_quote(s), po_quote(old.get(s, ''))))
	return ''.join(out)


PH = re.compile(r'%(?:\d+\$)?[-+ 0#]*\d*(?:\.\d+)?[sdfxXhiouc%]')
TAG = re.compile(r'</?([a-zA-Z]+)[^>]*>')


def check_translation(msgid, msgstr):
	problems = []
	if PH.findall(msgid) != PH.findall(msgstr):
		problems.append('placeholders %s != %s' % (PH.findall(msgid), PH.findall(msgstr)))
	if sorted(TAG.findall(msgid)) != sorted(TAG.findall(msgstr)):
		problems.append('HTML tags differ')
	if re.findall(r'href="[^"]*"', msgid) != re.findall(r'href="[^"]*"', msgstr):
		problems.append('href differs')
	if msgstr != canon(msgstr):
		problems.append('leading/trailing or repeated whitespace')
	return problems


def main():
	check = '--check' in sys.argv[1:]
	found, errors = scan()
	for e in errors:
		print('ERROR: ' + e)
	pot = render_pot(found)
	fail = bool(errors)

	if check:
		cur = io.open(POT, encoding='utf-8').read() if os.path.exists(POT) else ''
		if cur != pot:
			print('ERROR: %s is not current: run python3 scripts/i18n-sync.py' % os.path.relpath(POT, ROOT))
			fail = True
	else:
		os.makedirs(os.path.dirname(POT), exist_ok=True)
		io.open(POT, 'w', encoding='utf-8', newline='\n').write(pot)

	langs = sorted(d for d in os.listdir(PO_DIR) if d != 'templates' and os.path.isdir(os.path.join(PO_DIR, d)))
	for lang in langs:
		path = os.path.join(PO_DIR, lang, 'easy-vless.po')
		entries = read_po(path) if os.path.exists(path) else []
		old = {e['id']: e['str'] for e in entries if e['id'] and not e['fuzzy']}
		missing = [s for s in found if not old.get(s)]
		obsolete = [s for s in old if s not in found]
		bad = []
		for s in found:
			if old.get(s):
				bad += ['%r: %s' % (s[:60], p) for p in check_translation(s, old[s])]
		if check:
			rendered = render_po(found, lang, old)
			if missing or obsolete or (os.path.exists(path) and io.open(path, encoding='utf-8').read() != rendered):
				fail = True
		else:
			io.open(path, 'w', encoding='utf-8', newline='\n').write(render_po(found, lang, old))
		fail = fail or bool(bad)
		print('%s: %d strings, %d translated, %d missing, %d obsolete, %d problems'
		      % (lang, len(found), len(found) - len(missing), len(missing), len(obsolete), len(bad)))
		for s in missing[:20]:
			print('  missing: %r' % s[:100])
		for s in obsolete[:20]:
			print('  obsolete: %r' % s[:100])
		for b in bad:
			print('  problem: ' + b)
	print('%d strings in %s' % (len(found), os.path.relpath(POT, ROOT).replace(os.sep, '/')))
	sys.exit(1 if fail else 0)


if __name__ == '__main__':
	main()
