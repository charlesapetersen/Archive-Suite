#!/usr/bin/env python3
"""Put figures.json into prototype.template.html where __FIGURES__ stands, writing prototype.html."""
import json, sys
tpl, fig, out = sys.argv[1:4]
data = json.dumps(json.load(open(fig)), ensure_ascii=False, separators=(",", ":"))
open(out, "w").write(open(tpl).read().replace("__FIGURES__", data))
print("wrote", out, len(data), "bytes of figures")
