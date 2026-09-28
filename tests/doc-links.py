#!/usr/bin/env python3
# Easy VLESS - link check of the Markdown documentation (static checks).
#
#   python3 tests/doc-links.py README.md docs/technical.md
#
# Every relative link and image [text](path) / [text](path#anchor) /
# [text](#anchor) must point to an existing file, and every #anchor to a
# heading of the target Markdown file (GitHub slug: lower case, punctuation
# other than "-" and "_" removed, spaces -> "-"). Code fences must be
# balanced. Prints PASS/FAIL lines; the exit code is the number of failures.

import os
import re
import sys


def strip_code(text):
	return re.sub(r'^```.*?^```', '', text, flags=re.S | re.M)


def slugs(path):
	body = strip_code(open(path, encoding='utf-8').read())
	return {re.sub(r'[^\w\- ]', '', h.strip().lower()).replace(' ', '-')
	        for h in re.findall(r'^#+[ \t]+(.+?)[ \t]*$', body, flags=re.M)}


def main():
	fails = 0
	for doc in sys.argv[1:]:
		text = open(doc, encoding='utf-8').read()
		base = os.path.dirname(doc)
		fences = len(re.findall(r'^```', text, flags=re.M))
		if fences % 2:
			print('FAIL: %s: code fences unbalanced' % doc)
			fails += 1
		n = 0
		before = fails
		for target in sorted(set(re.findall(r'\]\(([^)\s]+)\)', strip_code(text)))):
			if re.match(r'^[a-z]+://', target):
				continue
			n += 1
			path, _, anchor = target.partition('#')
			full = os.path.normpath(os.path.join(base, path)) if path else doc
			if not os.path.exists(full):
				print('FAIL: %s: link target missing: %s' % (doc, target))
				fails += 1
			elif anchor and full.endswith('.md') and anchor not in slugs(full):
				print('FAIL: %s: anchor without heading: %s' % (doc, target))
				fails += 1
		if fails == before:
			print('PASS: %s: %d relative links and anchors, code fences' % (doc, n))
	return fails


if __name__ == '__main__':
	sys.exit(min(main(), 100))
