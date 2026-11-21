"""Synthetic scratch experiment. Run through ops/autonomous/heavy-run.py; takes no archive path."""
from pathlib import Path
from tempfile import TemporaryDirectory
from hashlib import sha256
from io import BytesIO
from xml.etree import ElementTree as ET
import json
import random
import statistics
import subprocess
import time
import shutil

from PIL import Image
from pypdf import PdfReader, PdfWriter
from pypdf.generic import ArrayObject, DecodedStreamObject, DictionaryObject, NameObject, NumberObject, TextStringObject
import reportlab
from reportlab.lib.utils import ImageReader
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.pdfgen.canvas import Canvas


def run(*args):
    return subprocess.run(list(map(str, args)), capture_output=True, check=True).stdout


RDF = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
SUITE = "https://github.com/charlesapetersen/Archive-Suite/ns/pdf/1.0/"
PROBE = "urn:example:storage-probe"
OLD = b'{"rev":1,"year":"1958"}'
NEW = b'{"rev":2,"year":"1957"}'


def declaration(uri, prefix, prop, kind):
    return f"""<rdf:li rdf:parseType="Resource"><pdfaSchema:schema>{prefix}</pdfaSchema:schema><pdfaSchema:namespaceURI>{uri}</pdfaSchema:namespaceURI><pdfaSchema:prefix>{prefix}</pdfaSchema:prefix>
<pdfaSchema:property><rdf:Seq><rdf:li rdf:parseType="Resource"><pdfaProperty:name>{prop}</pdfaProperty:name><pdfaProperty:valueType>{kind}</pdfaProperty:valueType>
<pdfaProperty:category>external</pdfaProperty:category><pdfaProperty:description>Research fixture</pdfaProperty:description></rdf:li></rdf:Seq></pdfaSchema:property></rdf:li>"""


def packet(archival):
    ident = '<pdfaid:part>2</pdfaid:part><pdfaid:conformance>B</pdfaid:conformance>' if archival else ''
    return f"""<?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="{RDF}">
<rdf:Description rdf:about="" xmlns:pdfaid="http://www.aiim.org/pdfa/ns/id/" xmlns:dc="http://purl.org/dc/elements/1.1/"
 xmlns:archivesuite="{SUITE}" xmlns:probe="{PROBE}">
{ident}<dc:description><rdf:Alt><rdf:li xml:lang="x-default">Foreign description</rdf:li></rdf:Alt></dc:description>
<archivesuite:pageHeaders><rdf:Seq><rdf:li>Extracted text. Synthetic page</rdf:li><rdf:li/></rdf:Seq></archivesuite:pageHeaders>
<probe:facts>{OLD.decode()}</probe:facts></rdf:Description>
<rdf:Description rdf:about="" xmlns:pdfaExtension="http://www.aiim.org/pdfa/ns/extension/" xmlns:pdfaSchema="http://www.aiim.org/pdfa/ns/schema#" xmlns:pdfaProperty="http://www.aiim.org/pdfa/ns/property#">
<pdfaExtension:schemas><rdf:Bag>{declaration(SUITE,'archivesuite','pageHeaders','Seq Text')}{declaration(PROBE,'probe','facts','Text')}</rdf:Bag></pdfaExtension:schemas>
</rdf:Description></rdf:RDF></x:xmpmeta>
<?xpacket end="w"?>""".encode()


def stream(data, **attrs):
    obj = DecodedStreamObject()
    obj.set_data(data)
    for key, value in attrs.items():
        obj[NameObject('/' + key)] = value
    return obj


def fixture(folder, archival):
    name = 'archival' if archival else 'ordinary'
    image_size = 128 if archival else 1600
    pixels = random.Random(49).randbytes(image_size * image_size * 3)
    img = ImageReader(Image.frombytes('RGB', (image_size, image_size), pixels))
    memory = BytesIO()
    canvas = Canvas(memory, pagesize=(400, 400), invariant=1)
    for i in (1, 2):
        canvas.setFont('ProbeVera', 14)
        canvas.drawString(20, 360, f'Synthetic catalogue page {i}')
        canvas.drawImage(img, 20, 50, width=270, height=270)
        if i == 1 and not archival:
            canvas.bookmarkPage('start')
            canvas.addOutlineEntry('Start', 'start')
            canvas.linkURL('https://example.invalid', (20, 350, 250, 380))
            canvas.acroForm.textfield(name='probe', value='kept', x=20, y=10, width=200, height=28)
        canvas.showPage()
    canvas.save()
    writer = PdfWriter(clone_from=BytesIO(memory.getvalue()))
    writer.metadata = None
    catalog = writer.root_object
    catalog[NameObject('/Metadata')] = writer._add_object(stream(packet(archival), Type=NameObject('/Metadata'), Subtype=NameObject('/XML')))
    if archival:
        profile = Path('/System/Library/ColorSync/Profiles/sRGB Profile.icc').read_bytes()
        intent = DictionaryObject({
            NameObject('/Type'): NameObject('/OutputIntent'), NameObject('/S'): NameObject('/GTS_PDFA1'),
            NameObject('/OutputConditionIdentifier'): TextStringObject('sRGB'),
            NameObject('/DestOutputProfile'): writer._add_object(stream(profile, N=NumberObject(3)))})
        catalog[NameObject('/OutputIntents')] = ArrayObject([writer._add_object(intent)])
    else:
        writer.add_attachment('witness.txt', b'Synthetic attachment')
        writer.pages[1].rotate(90)
    raw = folder / (name + '-raw.pdf')
    writer.write(raw)
    base = folder / (name + '.pdf')
    run('qpdf', '--force-version=1.7', '--object-streams=disable', '--stream-data=preserve',
        '--newline-before-endstream', raw, base)
    return base


def metadata(reader):
    return reader.root_object['/Metadata'].get_data()


def revise(base, out, mode):
    if mode == 'fixed packet':
        # Fixture-specific cost floor: unique literal, identical length, uncompressed stream.
        # Materialize a new staged copy. Deliberately accepts no external input.
        original = base.read_bytes()
        assert len(OLD) == len(NEW) and original.count(OLD) == 1
        out.write_bytes(original.replace(OLD, NEW))
    elif mode == 'ExifTool':
        supplied = out.with_suffix('.xmp')
        supplied.write_bytes(metadata(PdfReader(base)).replace(OLD, NEW))
        # All paths are experiment-owned. ExifTool edits the staged copy.
        shutil.copyfile(base, out)
        run('exiftool', '-overwrite_original', '-XMP<=' + str(supplied), out)
    else:
        writer = (PdfWriter(base, incremental=True) if mode == 'incremental'
                  else PdfWriter(clone_from=base))
        obj = writer.root_object['/Metadata']
        data = obj.get_data()
        assert data.count(OLD) == 1
        obj.set_data(data.replace(OLD, NEW))
        writer.write(out)


def snapshot(path):
    reader = PdfReader(path, strict=True)
    xmp = metadata(reader)
    parsed = ET.fromstring(xmp)
    record = json.loads(parsed.find('.//{' + PROBE + '}facts').text)
    digest = lambda data: sha256(data).hexdigest()
    pages = []
    for i, page in enumerate(reader.pages, 1):
        pixels = run('/opt/homebrew/bin/pdftoppm', '-f', i, '-l', i, '-singlefile', '-r', 72, path)
        assert pixels.startswith(b'P6')
        pages.append((digest(pixels), digest(page.get_contents().get_data()), list(page.mediabox), list(page.cropbox),
                      page.rotation, [digest(x.data) for x in page.images],
                      [a.get_object()['/Subtype'] for a in page.get('/Annots', [])]))
    assert b'Synthetic catalogue page' in (text := run('pdftotext', '-layout', path, '-'))
    # The packet wrapper and padding can change while element values and order survive.
    normalized = ET.tostring(ET.fromstring(xmp.replace(NEW, OLD)))
    return (record, digest(normalized), pages, digest(text),
            repr([(k, v.get('/V')) for k, v in (reader.get_fields() or {}).items()]),
            [d.title for d in reader.outline], {k: [digest(v) for v in vs] for k, vs in reader.attachments.items()})


def validate(paths):
    verification = subprocess.run(['verapdf', '--flavour', '2b', '--format', 'xml', *paths], capture_output=True)
    if not verification.stdout.startswith(b'<?xml'):
        print(verification.stdout[:1200], verification.stderr[:1200])
    xml = ET.fromstring(verification.stdout)
    summary = xml.find('.//batchSummary')
    assert int(summary.get('totalJobs')) == len(paths)
    assert all(int(summary.get(key)) == 0 for key in ('failedToParse', 'encrypted', 'outOfMemory', 'veraExceptions'))
    reports = summary.find('validationReports')
    assert int(reports.get('failedJobs')) == 0
    verdicts = {}
    for job in xml.findall('.//jobs/job'):
        item = Path(job.findtext('item/name')).name
        report = job.find('validationReport')
        verdicts[item] = report.get('isCompliant') == 'true'
        print(item, '2b', report.get('isCompliant'), [(r.get('clause'), r.get('testNumber'))
              for r in report.findall('.//rule') if r.get('status') == 'failed'])
    print(summary.attrib)
    return [verdicts[path.name] for path in paths]


def main(folder):
    pdfmetrics.registerFont(TTFont('ProbeVera', str(Path(reportlab.__file__).parent / 'fonts/Vera.ttf')))
    for archival in (True, False):
        base = fixture(folder, archival)
        baseline = snapshot(base)
        original = base.read_bytes()
        paths = [base]
        print(base.name, len(original), sha256(original).hexdigest())
        for mode in ('fixed packet', 'ExifTool', 'incremental', 'full'):
            out = folder / (base.stem + '-' + mode.replace(' ', '-') + '.pdf')
            samples = []
            for _ in range(5):
                start = time.perf_counter()
                revise(base, out, mode)
                samples.append((time.perf_counter() - start) * 1000)
            data = out.read_bytes()
            result = snapshot(out)
            assert result[0] == json.loads(NEW) and result[1:] == baseline[1:]
            checked = subprocess.run(['qpdf', '--check', out], capture_output=True)
            print('qpdf', checked.returncode, checked.stderr.decode().strip())
            if checked.returncode:
                assert mode == 'incremental' and checked.returncode == 3
                assert b'xref entry for the xref stream itself is missing' in checked.stderr
            print(mode, len(data), 'prefix', data.startswith(original), 'old literal', OLD in data,
                  'ms', [round(s, 2) for s in samples], 'median', round(statistics.median(samples), 2))
            paths.append(out)
        if archival:
            assert all(validate(paths))
        assert base.read_bytes() == original


if __name__ == '__main__':
    with TemporaryDirectory(prefix='w49-storage-') as scratch:
        main(Path(scratch))
