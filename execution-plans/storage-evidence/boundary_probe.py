"""Local boundary and transfer controls for storage-simplify.md. No input paths or accounts."""
from hashlib import sha256
from io import BytesIO
import json
import os
from pathlib import Path
import shutil
from statistics import median
import subprocess
from tempfile import TemporaryDirectory
from time import perf_counter
from zipfile import ZipFile

from pypdf import PdfReader, PdfWriter
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
import reportlab

from metadata_probe import fixture, metadata, NEW, OLD, revise, run, SUITE, validate


def compare_signatures(scratch, base):
    database = scratch / 'nss'
    database.mkdir()
    nss = 'sql:' + str(database)
    key, cert, identity = [scratch / name for name in ('test.key', 'test.crt', 'identity.p12')]
    run('certutil', '-N', '-d', nss, '--empty-password')
    run('openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
        '-subj', '/CN=W49 synthetic/', '-keyout', key, '-out', cert)
    run('openssl', 'pkcs12', '-export', '-name', 'W49 synthetic', '-inkey', key, '-in', cert,
        '-passout', 'pass:', '-out', identity)
    run('pk12util', '-i', identity, '-d', nss, '-W', '', '-K', '')

    signed = scratch / 'signed.pdf'
    appended = scratch / 'appended-after-signing.pdf'
    signature_tool = ('pdfsig', '-backend', 'NSS', '-nssdir', database)
    run(*signature_tool, '-add-signature', '-nick', 'W49 synthetic', base, signed)
    revise(signed, appended, 'ExifTool')
    for path in (signed, appended):
        report = run(*signature_tool, '-nocert', '-no-ocsp', path).decode()
        print(path.name, report)
        assert 'Signature is Valid' in report
        coverage = 'Total document signed' if path == signed else 'Not total document signed'
        assert coverage in report


def transfer(scratch, original, changed):
    members = {
        'E/file.pdf': changed, 'S/file.pdf': original, 'S/file.pdf.archivesuite.json': NEW,
        'F/file.pdf': original, 'F/.archivesuite/items.json': NEW,
        'P/item.package/file.pdf': original, 'P/item.package/facts.json': NEW,
    }
    bundle = scratch / 'transport.zip'
    with ZipFile(bundle, 'w') as writer:
        for name, data in members.items():
            writer.writestr(name, data)
    with ZipFile(bundle) as reader:
        for name, data in members.items():
            copied = reader.read(name)
            assert sha256(copied).digest() == sha256(data).digest()
            if name.endswith('.pdf'):
                current = NEW in metadata(PdfReader(BytesIO(copied)))
                print(name, 'detached PDF contains current facts:', current)
                assert current == name.startswith('E/')

    source = scratch / 'attribute.pdf'
    copied = scratch / 'bytes-only.pdf'
    attr = 'org.example.w49.scratch'
    source.write_bytes(changed)
    run('/usr/bin/xattr', '-w', attr, 'SYNTHETIC', source)
    copied.write_bytes(source.read_bytes())
    assert copied.read_bytes() == source.read_bytes()
    assert attr in run('/usr/bin/xattr', source).decode().splitlines()
    assert attr not in run('/usr/bin/xattr', copied).decode().splitlines()


def json_timings(scratch):
    for strategy, count in [('companion', 1), ('folder', 1000), ('package member', 1)]:
        original = {str(i): json.loads(OLD) for i in range(count)}
        encoded = json.dumps(original, separators=(',', ':'))
        live = scratch / 'records.json'
        candidate = scratch / 'candidate.json'
        samples = []
        for _ in range(5):
            live.write_text(encoded)
            start = perf_counter()
            records = json.loads(live.read_bytes())
            records['0'] = json.loads(NEW)
            candidate.write_text(json.dumps(records, separators=(',', ':')))
            candidate.replace(live)
            samples.append(1000 * (perf_counter() - start))
        print(strategy, len(encoded), 'bytes, median ms', median(samples), samples)


def main(scratch):
    pdfmetrics.registerFont(TTFont('ProbeVera', str(Path(reportlab.__file__).parent / 'fonts/Vera.ttf')))
    base = fixture(scratch, archival=True)
    original = base.read_bytes()
    before = sha256(original).digest()
    xmp = metadata(PdfReader(base))
    revised = scratch / 'good.xmp'
    revised.write_bytes(xmp.replace(OLD, NEW))

    def append_packet(source, destination, packet):
        shutil.copyfile(source, destination)
        run('exiftool', '-overwrite_original', '-XMP<=' + str(packet), destination)

    changed = scratch / 'changed.pdf'
    append_packet(base, changed, revised)
    bad = scratch / 'bad-schema.pdf'
    packet = scratch / 'other.xmp'
    packet.write_bytes(revised.read_bytes().replace(b'>facts</pdfaProperty:name>', b'>other</pdfaProperty:name>'))
    append_packet(base, bad, packet)
    assert validate([base, changed, bad]) == [True, True, False]

    writer = PdfWriter(clone_from=base)
    del writer.root_object['/Metadata']
    absent = scratch / 'absent.pdf'
    writer.write(absent)
    assert '/Metadata' not in PdfReader(absent).root_object
    inserted = scratch / 'inserted.pdf'
    append_packet(absent, inserted, revised)
    assert NEW in metadata(PdfReader(inserted))

    linear = scratch / 'linear.pdf'
    after = scratch / 'linear-edited.pdf'
    run('qpdf', '--linearize', base, linear)
    append_packet(linear, after, revised)
    for path in (linear, after):
        print(path.name, [s for s in run('pdfinfo', path).decode().splitlines() if 'Optimized:' in s])
    encrypted = scratch / 'locked.pdf'
    run('qpdf', '--encrypt', 'probe-open', 'probe-owner', '256', '--', base, encrypted)
    encrypted_digest = sha256(encrypted.read_bytes()).digest()
    assert PdfReader(encrypted).is_encrypted
    refused = subprocess.run(['pdfinfo', encrypted], capture_output=True)
    assert refused.returncode and b'password' in refused.stderr.lower()
    assert sha256(encrypted.read_bytes()).digest() == encrypted_digest
    compare_signatures(scratch, base)

    branch = scratch / 'other.pdf'
    packet.write_bytes(xmp.replace(OLD, b'{"rev":2,"year":"1962"}'))
    append_packet(base, branch, packet)
    assert NEW in metadata(PdfReader(changed)) and b'1962' in metadata(PdfReader(branch))
    assert branch.read_bytes() != changed.read_bytes()
    delta = changed.read_bytes()[len(original):]
    interrupted = scratch / 'partial.pdf'
    interrupted.write_bytes(original + delta[:len(delta)//2])
    checked = subprocess.run(['qpdf', '--check', interrupted], capture_output=True)
    print('half of appended suffix:', checked.returncode, checked.stderr.decode())
    assert checked.returncode == 3 and OLD in metadata(PdfReader(interrupted))
    live = scratch / 'live.pdf'
    candidate = scratch / 'staged.pdf'
    live.write_bytes(original)
    candidate.write_bytes(interrupted.read_bytes())
    assert sha256(live.read_bytes()).digest() == before
    candidate.write_bytes(changed.read_bytes())
    assert NEW in metadata(PdfReader(candidate))
    os.replace(candidate, live)
    assert live.read_bytes() == changed.read_bytes()
    # The second candidate was prepared against "before", checked serially here.
    assert sha256(live.read_bytes()).digest() != before and branch.is_file()
    assert base.read_bytes() == original

    ten = scratch / 'ten.pdf'
    shutil.copyfile(base, ten)
    sizes = []
    for rev in range(2, 12):
        value = json.dumps({'rev': rev, 'title': 'Résumé ' + 'x' * (rev * 20)}, ensure_ascii=False).encode()
        packet.write_bytes(xmp.replace(OLD, value))
        run('exiftool', '-overwrite_original', '-XMP<=' + str(packet), ten)
        assert value in metadata(PdfReader(ten))
        sizes.append(ten.stat().st_size)
    print('ten successive edits:', sizes, 'original prefix:', ten.read_bytes().startswith(original))

    # Headless PDFKit read/write control. No app or window is opened.
    swift = scratch / 'resave.swift'
    swift.write_text('''import Foundation
import PDFKit
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
guard let pdf = PDFDocument(url: input), pdf.write(to: output) else { exit(1) }
''')
    native = scratch / 'resaved.pdf'
    run('swift', '-module-cache-path', scratch / 'swift-cache', swift, changed, native)
    reader = PdfReader(native)
    native_xmp = metadata(reader)
    print('PDFKit save:', native.stat().st_size, len(reader.pages), NEW in native_xmp,
          SUITE.encode() in native_xmp, '/OutputIntents' in reader.root_object)
    assert validate([native]) == [True]
    transfer(scratch, original, changed.read_bytes())
    json_timings(scratch)


if __name__ == '__main__':
    with TemporaryDirectory(prefix='w49-boundary-') as folder:
        main(Path(folder))
