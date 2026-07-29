#!/usr/bin/env node
/**
 * Lightweight unit checks for caption parsing + numbered translation parsing.
 * Run: node scripts/test-core.mjs
 */
import assert from 'node:assert/strict';
import { parseCaptionBody } from '../renderer/subtitle.js';
import { parseNumbered } from '../renderer/translation.js';

const json3 = JSON.stringify({
  events: [
    { tStartMs: 0, dDurationMs: 1000, segs: [{ utf8: 'Hello' }] },
    { tStartMs: 1000, dDurationMs: 1500, segs: [{ utf8: 'World' }] },
    { tStartMs: 2500, segs: [{ utf8: 'World' }] },
  ],
});
const jsonSubs = parseCaptionBody(json3);
assert.equal(jsonSubs.length, 2, 'adjacent duplicate World cues should merge');
assert.equal(jsonSubs[0].text, 'Hello');
assert.equal(jsonSubs[1].text, 'World');
assert.ok(jsonSubs[1].duration >= 1.5);

const xml = `<?xml version="1.0"?><transcript>
  <text start="1.5" dur="2.0">Foo &amp; bar</text>
  <text start="4" dur="1">Baz</text>
</transcript>`;
const xmlSubs = parseCaptionBody(xml);
assert.equal(xmlSubs.length, 2);
assert.equal(xmlSubs[0].text, 'Foo & bar');
assert.equal(xmlSubs[0].start, 1.5);

const numbered = parseNumbered('1. 你好\n2. 世界\n补充一行\n3. 再见', 3);
assert.deepEqual(numbered, ['你好', '世界 补充一行', '再见']);

const empty = parseCaptionBody('   ');
assert.deepEqual(empty, []);

console.log('✓ desktop core tests passed');
