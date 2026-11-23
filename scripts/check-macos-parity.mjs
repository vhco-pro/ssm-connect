#!/usr/bin/env node
// Copyright (c) 2026 VH & Co BV. Licensed under the Apache License 2.0. See LICENSE for details.
//
// Checks that every control the macOS interface declares has an entry in contracts/macos-parity.json,
// the inventory the Windows and Linux shells are held to (AC-29 in
// docs/specs/cross-platform-client.spec.md). It reads the SwiftUI views, lists each control with its
// title or title expression, and fails on a control with no inventory entry, on an inventory entry
// whose control is gone, and on a control type it does not know, so a new kind of control cannot
// slip past it.
//
//   scripts/check-macos-parity.mjs [--views <dir>] [--inventory <file>] [--list]
//
// --list prints the controls found, one per line, as "<file>|<control>|<title>".

import { readFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const args = process.argv.slice(2);
const option = (name, fallback) => {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : fallback;
};
const viewsDir = option('--views', join(root, 'SSMConnectKit/Sources/SSMConnectUI'));
const inventoryPath = option('--inventory', join(root, 'contracts/macos-parity.json'));

// The views that make up the macOS interface the shells must match.
const VIEWS = ['MenuContentView.swift', 'SettingsView.swift', 'ProfileEditorView.swift', 'LogView.swift', 'AboutView.swift'];

// Control types the check reads. A view that uses any other interactive SwiftUI control fails until
// this list, and the inventory, cover it.
const KNOWN = ['Button', 'Toggle', 'Picker', 'Stepper', 'Menu', 'TextField', 'SecureField', 'SettingsLink', 'Link', 'DisclosureGroup'];
const UNKNOWN = ['Slider', 'DatePicker', 'MultiDatePicker', 'ColorPicker', 'TextEditor', 'ShareLink', 'PasteButton',
  'EditButton', 'RenameButton', 'NavigationLink', 'ControlGroup'];

// Index just past the bracket that closes the one at `open`, skipping string literals.
function closeOf(source, open) {
  const pairs = { '(': ')', '{': '}', '[': ']' };
  const stack = [];
  for (let i = open; i < source.length; i++) {
    const ch = source[i];
    if (ch === '"') {
      for (i++; i < source.length && source[i] !== '"'; i++) if (source[i] === '\\') i++;
      continue;
    }
    if (pairs[ch]) stack.push(pairs[ch]);
    else if (ch === stack[stack.length - 1]) {
      stack.pop();
      if (!stack.length) return i + 1;
    }
  }
  return source.length;
}

const literal = (text) => text.match(/^"((?:[^"\\]|\\.)*)"/)?.[1];

// A control's title: its first argument when that is a string literal or an expression; otherwise
// the `.help("…")` chained after it, or the text of its label closure.
function titleOf(source, start, type) {
  let i = start + type.length;
  while (/\s/.test(source[i])) i++;
  let argument = null;
  if (source[i] === '(') {
    const end = closeOf(source, i);
    const inner = source.slice(i + 1, end - 1).trim();
    const first = literal(inner);
    if (first !== undefined) return first;
    const head = inner.split(/,\s*(?=[a-zA-Z]+:)/)[0].trim();
    if (head && !/^(action|isOn|destination|selection|value|text)\s*:/.test(head)) argument = head;
    i = end;
    while (/\s/.test(source[i])) i++;
  }
  if (argument) return argument;
  let label = '';
  // The action closure, then an optional `label:` closure.
  if (source[i] === '{') {
    let end = closeOf(source, i);
    let rest = source.slice(end).match(/^\s*label:\s*\{/);
    let labelStart = i;
    if (rest) { labelStart = end + rest[0].length - 1; end = closeOf(source, labelStart); }
    label = source.slice(labelStart, end);
    i = end;
  }
  const chained = source.slice(i, i + 400).match(/^(?:\s*\.[a-zA-Z]+\([^)]*\))*?\s*\.help\("((?:[^"\\]|\\.)*)"\)/);
  if (chained) return chained[1];
  const text = label.match(/(?:Label|Text)\("((?:[^"\\]|\\.)*)"/);
  if (text) return text[1];
  const image = label.match(/Image\(systemName:\s*"([^"]*)"/);
  return image ? `image:${image[1]}` : '';
}

// Local view helpers that wrap a control: their call sites count as that control, and the wrapped
// control inside the helper (whose title is the helper's parameter) does not.
const HELPERS = { portField: 'TextField' };

export function controls(dir = viewsDir) {
  const found = [];
  const unknown = [];
  for (const file of VIEWS) {
    let source;
    try { source = readFileSync(join(dir, file), 'utf8'); } catch { continue; }
    // Comments never declare controls; `//` inside a URL string is not a comment.
    source = source.replace(/(^|\s)\/\/[^\n]*/g, '$1');
    for (const type of KNOWN) {
      const pattern = new RegExp(`(?<![A-Za-z0-9_.])${type}(?=\\s*[({])`, 'g');
      let match;
      while ((match = pattern.exec(source))) {
        const title = titleOf(source, match.index, type);
        if (title === 'title') continue; // the control inside a helper below
        found.push({ file, control: type, title });
      }
    }
    for (const [helper, type] of Object.entries(HELPERS)) {
      const pattern = new RegExp(`(?<![A-Za-z0-9_.])${helper}\\(\\s*"((?:[^"\\\\]|\\\\.)*)"`, 'g');
      let match;
      while ((match = pattern.exec(source))) found.push({ file, control: type, title: match[1] });
    }
    const alert = /addButton\(withTitle:\s*"((?:[^"\\]|\\.)*)"\)/g;
    let match;
    while ((match = alert.exec(source))) found.push({ file, control: 'AlertButton', title: match[1] });
    for (const type of UNKNOWN) {
      if (new RegExp(`(?<![A-Za-z0-9_.])${type}(?=\\s*[({])`).test(source)) unknown.push({ file, control: type.replace(/\\.*/, '') });
    }
  }
  return { found, unknown };
}

const key = (c) => `${c.file}|${c.control}|${c.title}`;

function main() {
  const { found, unknown } = controls();
  if (args.includes('--list')) {
    for (const c of found) console.log(key(c));
    return 0;
  }
  const inventory = JSON.parse(readFileSync(inventoryPath, 'utf8'));
  const listed = new Map();
  for (const entry of inventory.entries) {
    const k = key(entry.macos);
    listed.set(k, (listed.get(k) ?? 0) + 1);
  }
  const seen = new Map();
  for (const c of found) seen.set(key(c), (seen.get(key(c)) ?? 0) + 1);
  const problems = [];
  for (const u of unknown) problems.push(`unknown control type ${u.control} in ${u.file}: add it to the check and the inventory`);
  for (const [k, n] of seen) {
    if ((listed.get(k) ?? 0) < n) problems.push(`no inventory entry for ${k}${n > 1 ? ` (${n} in the view)` : ''}`);
  }
  for (const [k, n] of listed) {
    if ((seen.get(k) ?? 0) < n) problems.push(`inventory entry without its macOS control: ${k}`);
  }
  if (problems.length) {
    for (const p of problems) console.error(p);
    console.error(`macOS parity: ${problems.length} problem(s)`);
    return 1;
  }
  console.log(`macOS parity: ${found.length} controls, all in the inventory`);
  return 0;
}

if (import.meta.url === `file://${process.argv[1]}`) process.exit(main());
