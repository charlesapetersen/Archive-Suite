# Archive Processor changelog

## Unreleased

- Transcription now explicitly includes the foreground sheet's headers, footers, citations, stamps and
  database/archive copyright lines. It writes bullets as `*` and unreadable words as `[illegible]`, omits
  empty checkboxes and other non-text symbols, and excludes text on neighboring sheets or folders.
  Classification and rotation instructions and the response format are unchanged. Applies to backends using the shared
  model prompt; Apple Vision and Mistral's dedicated OCR endpoint do not take this instruction.
