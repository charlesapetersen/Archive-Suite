import Foundation

/// The window prompts, copied verbatim from the bench (`scripts/segbench/method_window.py` `PROMPT`, id w1;
/// `method_gemini.py` `PROMPT`, id g1) with Python `str.format` placeholders. Each approach in options.json names
/// its voter's prompt id, and `WindowVoter.resolve` fails if the two disagree; the engine test renders both
/// prompts for a synthetic window and compares them with the bench's own rendering, byte for byte. Change a
/// prompt only by changing the bench and re-measuring; then re-export the fixture
/// (`scripts/segbench/export_engine_fixture.py`) and copy the new text here, or the engine test fails.
///
/// w1 was written for `claude -p`, which reads the window's files with its Read tool. The bench's API cost
/// figure was counted with that same text after the inline images (`options.py` `tokens_claude`), so the API
/// route sends it unchanged.
///
/// c1 is g1 with the image lines rewritten for `codex exec` (`method_window_cues.py` `prompt_template("codex")`,
/// the ChatGPT voter measured through Codex on the subscription): it says the images are attached and not to run
/// commands. The app's API route attaches them inline, so the text stands as measured (`W36.seg-opt-siwc` owns the
/// route).
enum WindowPromptID: String, Sendable {
    case w1, g1, c1

    var template: String {
        switch self {
        case .w1: return WindowPromptTemplates.w1
        case .g1: return WindowPromptTemplates.g1
        case .c1: return WindowPromptTemplates.c1
        }
    }
}

enum WindowPromptTemplates {
    static let w1 = #"""
You are helping an archivist split a stream of page photographs into documents.

The photographs were taken one after another while working through an archive box, in box order.
This window holds {k} consecutive photographs from the stream. Their files are in the current directory:

{files}

FIRST read every one of these image files with the Read tool (issue all the Read calls together, in one
turn). Then answer from the images, using the OCR text below as a help for reading (the OCR is automatic
and has errors; the image wins when they disagree).

WHAT THE STREAM CONTAINS
- Box label photos: the end of an archive box or a label on it (repository, collection name, box number,
  call number). Kind "box".
- Folder label photos: a folder tab or folder label (folder title, dates, folder number), photographed
  to mark the start of a folder. Kind "folder".
- Document pages: everything else. A document is one item an archivist would describe on its own: a
  letter, a memo, a report, a newspaper clipping, a form, a list, a printed item. Many documents are one
  page; some run to many pages.

THE RULES FOR WHAT IS ONE DOCUMENT
1. An enclosure (a complete item sent with a letter: a report, a pamphlet, someone else's letter) is its
   own document: its first page is new.
2. An attachment made to go with a letter or memo ("Attachment A", a list, a table, a budget) with no
   date, author or heading of its own continues that letter.
3. A carbon copy of a letter is a document like any letter: its first page is new.
4. Two copies of the same document kept together are two documents: the second copy's first page is new.
5. The same page photographed twice by mistake: the repeat continues.
6. An envelope next to the letter it held continues that letter; an envelope on its own is a document.
7. Each newspaper article is its own document; a second piece of the same article ("continued on page
   8") continues it; several articles in one photograph are one document.
8. A photograph (a print) is its own document; a photo of its back continues it.
9. A blank page or the blank back of a sheet continues the document it belongs to.
10. A box or folder label photo is never part of a document: every gap next to one is "new".

CUES
- Continue: a page number of 2 or more ("-2-", "Page 2", "2."), often with the addressee's name and the
  date repeated as a running head; text that runs on from the previous page mid-sentence or
  mid-paragraph; the same typescript, report layout or numbered sections continuing; the previous page
  ends without a closing or signature and this page carries on and ends with one; a table or list
  carrying on.
- New: a letterhead; a date line, inside address and salutation ("Dear ..."); a memo heading (TO /
  FROM / SUBJECT / MEMORANDUM); a title page; a new masthead, headline or dateline of a clipping;
  "Page 1"; a clear change of paper, type, author or subject. A previous page that ends with a closing
  ("Sincerely", "Yours truly"), a signature, typist's initials, "cc:" or "Enclosure" makes the next
  page likely new — but an attachment or enclosure may follow (rules 1 and 2).
- Not evidence on their own: two letters to the same person, or on the same subject, are still two
  documents; a similar look alone does not join pages.

THE OCR TEXT OF EACH PAGE (truncated at {max_text} characters where longer)
{texts}

ANSWER with one JSON object and nothing else (no prose, no code fence):
{{
  "pages": [{{"page": <page number>, "kind": "box" | "folder" | "document"}}, ...one per page, in order],
  "boundaries": [
    {{"between": [<n>, <n+1>], "decision": "new" | "continue", "cue": "<the cue you saw, under 15 words>",
      "confidence": <0 to 1, your probability that the decision is right>}},
    ...one for every gap between consecutive pages in this window: {gaps}
  ]
}}
"new" means page n+1 starts a new document (or is a label photo, or follows one); "continue" means
page n+1 belongs to the same document as page n. Use confidence honestly: 0.95 and above only when the
cue is unambiguous, about 0.6 when you are close to guessing.

"""#

    static let g1 = #"""
You are helping an archivist split a stream of page photographs into documents.

The photographs were taken one after another while working through an archive box, in box order. The
{k} images above are consecutive photographs from that stream, each introduced by its page number.
Answer from the images. The OCR text below is automatic and has errors; the image wins when they
disagree.

WHAT THE STREAM CONTAINS
- Box label photos: the end of an archive box or a label on it (repository, collection, box number).
  Kind "box".
- Folder label photos: a folder tab or folder label (title, dates, folder number). Kind "folder".
- Document pages: everything else. A document is one item an archivist would describe on its own: a
  letter, memo, report, newspaper clipping, form, list or printed item. Many are one page; some run long.
- The photographs are in the order they were taken and are never reordered. Runs of several box or
  folder photos in a row are normal: an empty box or folder was examined and nothing in it was
  photographed. Each such photo is still kind "box" or "folder".

WHAT IS ONE DOCUMENT (the archive's rules)
1. An enclosure (a complete item sent with a letter: a report, a pamphlet, someone else's letter) is its
   own document: its first page is new.
2. An attachment made to go with a letter or memo ("Attachment A", a list, a table, a budget) with no
   date, author or heading of its own is part of that letter: continue.
3. A carbon copy of a letter is the letter: its first page is new, like any letter.
4. Two copies of the same document kept together are two documents: the second copy's first page is new.
5. The same page photographed twice is the same document: the repeat continues.
6. An envelope next to the letter it held is part of that letter: continue. An envelope on its own is
   a document.
7. Each newspaper article is its own document; a second piece of the same article ("continued on page
   8") continues it; several articles in one photograph are one document.
8. A photograph (a print) is its own document; a photo of its back (caption, stamp) continues it.
9. A blank page or blank back of a sheet is part of the document it belongs to: continue.
10. A full magazine is ONE document, cover to end; its articles are not separate clippings.
11. A box or folder label photo is never part of a document: every gap next to one is "new".

THINGS THAT MISLEAD, FROM THIS ARCHIVE
- Show-through. Much of the paper is thin onion skin, and the photo (and the OCR) picks up text from
  the sheet BENEATH. A "-2-", "Page 2" or other text read through the paper belongs to the next
  sheet, not this one. A page number is a continuation cue ONLY if it is printed on this sheet itself.
  When the OCR shows a page number but the page also has its own new date, heading, letterhead or
  salutation, trust those: it starts a new document.
- A small item on a full sheet. A telegram, note or small cover letter is often photographed lying on
  top of a full page; the full page shows around or behind it. The small item is this photo's
  document; the sheet underneath is the NEXT document's first page, so the next photo (that sheet
  shown on its own) starts a new document rather than continuing the small item.
- Newspaper clippings. A byline ("By ..."), a wire-service credit such as "(AP)" or "(UPI)", or a
  section heading such as "Opinion" marks the START of an article: continuation pieces of an article
  rarely carry a byline, and a wire service is credited on the first piece only. A newspaper page
  number printed at the top ("Page A8", "14") is where the clipping began in the paper, not a sign
  that it continues the clipping before it.

OTHER CUES
- Continue: a page number of 2 or more printed on this sheet, often with the addressee and date as a
  running head; text running on from the previous page mid-sentence; the same typescript, layout or
  numbered sections continuing; the previous page ending with no closing or signature and this page
  carrying on; a table or list carrying on.
- New: a letterhead; a date line, inside address and salutation ("Dear ..."); a memo heading (TO /
  FROM / SUBJECT / MEMORANDUM); a title page; a masthead or headline; "Page 1"; a clear change of
  paper, type, author or subject. A previous page ending with a closing, a signature, typist's
  initials, "cc:" or "Enclosure" makes the next page likely new, though an attachment or enclosure
  may follow (rules 1 and 2).
- Not evidence on their own: two letters to the same person or on the same subject are still two
  documents; a similar look alone does not join pages.

THE OCR TEXT OF EACH PAGE (truncated at {max_text} characters where longer; it may include text that
shows through from the sheet beneath)
{texts}

ANSWER in the JSON schema given: "pages" has one entry per page in this window ({pages}), in order,
with its kind; "boundaries" has one entry for every gap between consecutive pages: {gaps}.
"between" is [n, n+1]; "new" means page n+1 starts a new document (or is a label photo, or follows one);
"continue" means page n+1 belongs to the same document as page n. "cue" is the cue you relied on, under
15 words. "confidence" is your probability, 0 to 1, that the decision is right: 0.95 and above only when
the cue is unambiguous, about 0.6 when you are close to guessing.

"""#

    static let c1 = #"""
You are helping an archivist split a stream of page photographs into documents.

The photographs were taken one after another while working through an archive box, in box order. The
{k} images attached are consecutive photographs from that stream, attached in this order:

{files}

Answer from the images; do not run commands. The OCR text below is automatic and has errors; the image wins when they
disagree.

WHAT THE STREAM CONTAINS
- Box label photos: the end of an archive box or a label on it (repository, collection, box number).
  Kind "box".
- Folder label photos: a folder tab or folder label (title, dates, folder number). Kind "folder".
- Document pages: everything else. A document is one item an archivist would describe on its own: a
  letter, memo, report, newspaper clipping, form, list or printed item. Many are one page; some run long.
- The photographs are in the order they were taken and are never reordered. Runs of several box or
  folder photos in a row are normal: an empty box or folder was examined and nothing in it was
  photographed. Each such photo is still kind "box" or "folder".

WHAT IS ONE DOCUMENT (the archive's rules)
1. An enclosure (a complete item sent with a letter: a report, a pamphlet, someone else's letter) is its
   own document: its first page is new.
2. An attachment made to go with a letter or memo ("Attachment A", a list, a table, a budget) with no
   date, author or heading of its own is part of that letter: continue.
3. A carbon copy of a letter is the letter: its first page is new, like any letter.
4. Two copies of the same document kept together are two documents: the second copy's first page is new.
5. The same page photographed twice is the same document: the repeat continues.
6. An envelope next to the letter it held is part of that letter: continue. An envelope on its own is
   a document.
7. Each newspaper article is its own document; a second piece of the same article ("continued on page
   8") continues it; several articles in one photograph are one document.
8. A photograph (a print) is its own document; a photo of its back (caption, stamp) continues it.
9. A blank page or blank back of a sheet is part of the document it belongs to: continue.
10. A full magazine is ONE document, cover to end; its articles are not separate clippings.
11. A box or folder label photo is never part of a document: every gap next to one is "new".

THINGS THAT MISLEAD, FROM THIS ARCHIVE
- Show-through. Much of the paper is thin onion skin, and the photo (and the OCR) picks up text from
  the sheet BENEATH. A "-2-", "Page 2" or other text read through the paper belongs to the next
  sheet, not this one. A page number is a continuation cue ONLY if it is printed on this sheet itself.
  When the OCR shows a page number but the page also has its own new date, heading, letterhead or
  salutation, trust those: it starts a new document.
- A small item on a full sheet. A telegram, note or small cover letter is often photographed lying on
  top of a full page; the full page shows around or behind it. The small item is this photo's
  document; the sheet underneath is the NEXT document's first page, so the next photo (that sheet
  shown on its own) starts a new document rather than continuing the small item.
- Newspaper clippings. A byline ("By ..."), a wire-service credit such as "(AP)" or "(UPI)", or a
  section heading such as "Opinion" marks the START of an article: continuation pieces of an article
  rarely carry a byline, and a wire service is credited on the first piece only. A newspaper page
  number printed at the top ("Page A8", "14") is where the clipping began in the paper, not a sign
  that it continues the clipping before it.

OTHER CUES
- Continue: a page number of 2 or more printed on this sheet, often with the addressee and date as a
  running head; text running on from the previous page mid-sentence; the same typescript, layout or
  numbered sections continuing; the previous page ending with no closing or signature and this page
  carrying on; a table or list carrying on.
- New: a letterhead; a date line, inside address and salutation ("Dear ..."); a memo heading (TO /
  FROM / SUBJECT / MEMORANDUM); a title page; a masthead or headline; "Page 1"; a clear change of
  paper, type, author or subject. A previous page ending with a closing, a signature, typist's
  initials, "cc:" or "Enclosure" makes the next page likely new, though an attachment or enclosure
  may follow (rules 1 and 2).
- Not evidence on their own: two letters to the same person or on the same subject are still two
  documents; a similar look alone does not join pages.

THE OCR TEXT OF EACH PAGE (truncated at {max_text} characters where longer; it may include text that
shows through from the sheet beneath)
{texts}

ANSWER with one JSON object and nothing else (no prose, no code fence), shaped
{{"pages": [{{"page": <n>, "kind": "box" | "folder" | "document"}}, ...], "boundaries": [{{"between": [<n>, <n+1>], "decision": "new" | "continue", "cue": "<text>", "confidence": <0-1>}}, ...]}}. "pages" has one entry per page in this window ({pages}), in order,
with its kind; "boundaries" has one entry for every gap between consecutive pages: {gaps}.
"between" is [n, n+1]; "new" means page n+1 starts a new document (or is a label photo, or follows one);
"continue" means page n+1 belongs to the same document as page n. "cue" is the cue you relied on, under
15 words. "confidence" is your probability, 0 to 1, that the decision is right: 0.95 and above only when
the cue is unambiguous, about 0.6 when you are close to guessing.

"""#
}
