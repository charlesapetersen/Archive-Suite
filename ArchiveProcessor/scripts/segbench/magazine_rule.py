"""Rule 10 of the window prompts, before and after the article-within-issue rule (W46.seg-magazine-rule-redo).

Its own module so method_gemini (g1, g2) and method_whole (wh1, wh2) share it without an import cycle: methods
imports method_whole while method_gemini is still loading.
"""
RULE10_G1 = "10. A full magazine is ONE document, cover to end; its articles are not separate clippings.\n"
RULE10_G2 = """10. A magazine or newsletter issue is split by article. Its cover or contents page (masthead, issue
   date, table of contents) is one document; each article or editorial inside the issue starts a new one,
   and a later page of the same article continues it. An advertisement photographed between two pages of
   one article is part of that article: continue. Only where the articles cannot be told apart in photo
   order (one article's pages interleaved with another's) is the whole issue one document, cover to end.
"""
