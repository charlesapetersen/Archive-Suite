// Imports a CSL-JSON file with the installed Zotero's own importer (`Zotero.Utilities.Item.itemFromCSLJSON`, as the
// CSL JSON translator calls it) and prints the Zotero items as JSON: what a library would hold after File > Import.
// Usage: node import.js <zotero utilities dir> <csl.json>. Run through zotero-import.sh, which unpacks the utilities.
// W47.ct-zotero. Touches no Zotero library.
const fs = require('fs');
const path = require('path');
const [dir, input] = process.argv.slice(2);
globalThis.Zotero = { locale: 'en-US', debug: () => {}, isNode: true };
Zotero.Schema = require(path.join(dir, 'schema'));
Zotero.Utilities = require(path.join(dir, 'utilities'));
Zotero.Utilities.Item = require(path.join(dir, 'utilities_item'));
Zotero.Date = require(path.join(dir, 'date'));
Zotero.Schema.init(fs.readFileSync(path.join(dir, 'resource', 'schema', 'global', 'schema.json'), 'utf-8'));
Zotero.Date.init(fs.readFileSync(path.join(dir, 'resource', 'dateFormats.json'), 'utf-8'));
const CachedTypes = require(path.join(dir, 'cachedTypes'));
CachedTypes.setTypeSchema(require(path.join(dir, 'resource', 'zoteroTypeSchemaData')));
Object.assign(Zotero, CachedTypes);
const collator = new Intl.Collator(['en-US'], { numeric: true, sensitivity: 'base' });
Zotero.localeCompare = (a, b) => collator.compare(a, b);

const items = JSON.parse(fs.readFileSync(input, 'utf-8')).map((csl) => {
  const item = { itemType: null, creators: [], tags: [], attachments: [], seeAlso: [] };
  Zotero.Utilities.Item.itemFromCSLJSON(item, csl);
  return item;
});
process.stdout.write(JSON.stringify(items, null, 1));
