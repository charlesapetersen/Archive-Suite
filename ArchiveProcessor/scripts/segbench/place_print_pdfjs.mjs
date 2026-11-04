// W46.place-print: pdf.js text extraction (run from a directory holding pdfjs-dist; place_print.py copies it there). One
// line per run of text items ending in hasEOL, pdf.js's own line breaks.
import { getDocument } from 'pdfjs-dist/legacy/build/pdf.mjs';
const doc = await getDocument({ url: process.argv[2], verbosity: 0 }).promise;
const page = await doc.getPage(1);
const tc = await page.getTextContent();
let out = '';
for (const it of tc.items) { out += it.str ?? ''; if (it.hasEOL) out += '\n'; }
process.stdout.write(out);
