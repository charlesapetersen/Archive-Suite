# The next phase: proving the Suite works

Written 4 October 2026 for the owner's review. Status: **proposed, not approved.** Nothing in this plan runs until
you approve it. The daemon's version of the same plan is `01-daemon-plan.md` in this folder.

## Where things stand

The current queue ends with an initial version of three Mac apps and two phone apps, about 105,000 lines of
program code. Roughly 45,000 of those lines are automated tests. The tests are real work, but they answer a narrow
question: does each piece of code behave the way the agent that wrote it expected? They do not answer the questions
you care about. Can a historian reach every feature? Does it do the right thing with real archival material? Is it
pleasant enough to use every day?

A survey of the project on 4 October found the following.

**Completion has been overstated many times.** The trackers themselves record about fifteen cases. The largest was
Archive Notes, whose first eight build waves were all ticked done while whole features had no button or menu item
to reach them. Others include a test lane that printed a green tick after running zero tests, a safety check that
had never once passed, and two entries in the safety register describing protections that were never written.

**Most features have never been used for real.** Each app has a long list of features. For most of them the only
evidence is an automated test, often on a dozen fixture files. Your recorded hands-on passes date from July, before
large parts of the Reader and Notes were rewritten. Some specific gaps:

- Archive Processor has no ordinary tests of its own code at all. Its tests run the whole app with a test script.
  Its main job, processing a real box of photographs into tagged PDFs, has not been run on real material since July.
  Three of its four cloud AI providers have never been called through the app itself. Paid batch mode has never sent a
  real job. The USB phone connection has no button that starts it and has never been tried.
- In Archive Notes, typing a note and having it saved when you quit has never been tested by anything. That is the
  app's main activity. Real Zotero has never been connected; every Zotero test talks to a stand-in.
- Archive Reader has been timed on 150,000 made-up files but never with real document text. The full-text search,
  the main list and the library health panel have never been measured at the size of your collection.
- Some features described as shipped are not reachable. The Reader's single-click Read toggle and date pop-up
  exist in code that nothing uses. The Reader's guide promises a permanent record of every tag change, and no such
  record exists; undo is lost when the app quits.

**The safety checks have lapsed.** The daemon's full health check has not run on the last 58 changes, because it
only runs inside the daemon and Codex has done the work since August. It also never runs the tests for the shared
code that all three apps use.

**AI bug reports are only partly reliable.** About three in four findings from past AI reviews of this project
survived checking. Outside research agrees: AI reviewers often report bugs that are not there, and they are much
worse when asked to explain and fix at the same time. A finding is only worth acting on once something has been run
that shows the bug.

## What others do in this situation

Research on how teams verify software built by AI agents, from 2024 to 2026, points the same way on five points.

1. **A finished checkbox is not evidence.** Anthropic's own engineers found that agents declare features done when
   the parts pass their tests but the whole does not work. Their fix is a list of every feature that starts out
   marked "not working" and changes only when the feature has been used the way a person would use it.
2. **Agents bend tests to pass.** Controlled studies found agents editing or deleting tests that disagreed with
   their code. The remedy is tests written from the description of what the app should do, before anyone looks at
   the code, and protected from the agent that is fixing the code.
3. **The builder should not grade its own work.** A separate checker that drives the real app catches unwired and
   half-built features that the builder misses. It still misses about half of real problems, so it supplements a
   person rather than replacing one.
4. **Machines are good at certain kinds of bug.** Tools that look for crashes, freezes, memory errors, unreachable
   code, corrupted files and lost tags find real bugs with no judgement involved. They are cheap to run and their
   findings do not need arguing about.
5. **One real user doing real tasks finds what nothing else finds.** Short, repeated sessions with a fixed list of
   tasks reveal most usability problems. For this project you are that user.

## The plan in eight stages

The daemon does almost all of this work. Your part is described in its own section below.

**Stage 1. Finish the current queue.** This is already happening.

**Stage 2. Make the safety checks honest again.** The full health check runs at every hand-off, Codex included,
and includes the shared code's tests. Every app's on-screen test suite runs in full, in the virtual machine, and
passes. Tests that cannot fail are removed or fixed. Nothing else starts until this is done, because every later
stage depends on these checks telling the truth.

**Stage 3. Bring the iPhone app back.** It has been set aside since July and has fallen behind the Android app. The
daemon reinstalls what it needs to build and builds it. It then compares it feature by feature with Android, brings
it level, and adds it to the automated phone-to-Mac test. A real-phone check needs you and an iPhone.

**Stage 4. Write down what each app promised, and prove each promise.** For each app the daemon writes a feature
ledger, a plain list of every feature the plans and guides say exists. Each feature is described from the
promise, not from the code, and every line starts as "unproven". A line becomes "works" only when three things are
recorded: how a person reaches the feature, a test that goes through the real code, and a run on realistic
material with the result kept. Lines can also end as "broken", "unreachable" or "dropped". Whether to finish or drop
an unreachable feature is your decision. The ledger replaces checkboxes as the measure of done.

**Stage 5. Rehearse your four real uses on copies of real material.** These are end-to-end run-throughs, in the
virtual machine, never on your screen, and never on the real collection.

- Bulk OCR: process real photograph sets already in the project. Some have the correct answers recorded, so the
  daemon can measure how well the app splits and tags documents. Check every PDF it writes with independent tools.
- Reader triage: open a large copied sample of the collection and measure speed. Then work through it with marking,
  tag editing, renaming and undo, checking each file's tags directly after every step.
- Notes and Zotero: type real notes with real keystrokes, quit, reopen and confirm nothing was lost. Connect a real
  Zotero. Follow links between Notes and the Reader in both directions.
- Phone capture: run the whole route from phone to finished PDF with the review steps done by hand rather than
  skipped, on Android and on the revived iPhone app.

**Stage 6. Run the machine bug-finders.** The daemon adds tools that find crashes, freezes, memory errors, code
nothing ever runs, screens a person cannot fully operate, and files that break the apps' readers when slightly
damaged. Each finding needs a demonstration before it becomes work. Suspicions that cannot be shown go on a
separate list and do not enter the queue.

**Stage 7. Your guided sessions.** For each app the daemon prepares a session of about 45 minutes: a short list of
real tasks, the rehearsal material already loaded, and a one-page form for notes. You use the app and write down
what was confusing, slow or wrong. The daemon turns each note into a reproduced problem or a design question for
you. Several short rounds, repeated after fixes, work better than one long one.

**Stage 8. Fix, re-check and release.** Problems are fixed in order of harm, worst first. Each fix comes with a test
that failed before the fix. When the list is short, every rehearsal is run again and the daemon builds a release
candidate. You do a final pass with the ledgers in front of you. If it passes, the Suite is in use, and the
DEVONthink import and new features can resume.

## The rules that change for this phase

- **No new features** until the release candidate passes. The only new code is what it takes to finish or remove a
  feature in the ledger, or to fix a demonstrated bug.
- **Evidence or it did not happen.** A "works" claim must point to a kept record of a run. A bug must come with a
  demonstration.
- **The agent fixing a feature is not the one that confirms it.** A later, separate run re-checks it.
- **Tests written from the promise are protected.** A fix may not change what such a test expects without saying
  why, and the ledger records it.
- **The real collection is never written.** Rehearsals use copies.

## Your part

You make a handful of decisions, listed below. You run the guided sessions, perhaps one or two a week once Stage 7
begins. You do the iPhone check on a real phone if you have one. You do the final acceptance pass. Decisions the
daemon meets along the way, such as whether to finish or drop an unreachable feature, reach you through the usual
daemon report walkthrough, one at a time.

## Size

The daemon's version has about 45 items. Most should take one session and a few take two. Bugs found along the way
add more. At the daemon's past pace that is several weeks of unattended running. Paid AI calls for the rehearsals
should come to tens of dollars. The daemon states the cost before any run that pays a provider.

## Decisions for you

1. **Approve the plan,** or change it. Until you approve, the items are queued but blocked.
2. **The paused code reviews.** You paused AI whole-project reviews in July. This plan does not restart them. It
   finds bugs with tools, rehearsals and your sessions instead, and every finding must be demonstrated. Please
   confirm that is acceptable, or say if you want the reviews back as well.
3. **A sample of the real collection.** The Reader rehearsal needs real documents at real size. The proposal is
   that the daemon copies about 5,000 PDFs, together with their tags, out of the collection into a scratch folder,
   reading only.
4. **The iPhone.** Do you have an iPhone to test on? Do you have a paid Apple Developer account? Without one, an
   app installed from this Mac stops working after seven days and has to be reinstalled.
5. **Android screen tests.** In July you declined an Android test lane that needed an emulator. There is now a way to
   test the Android screens without one. It is offered once here; declining again is fine.
