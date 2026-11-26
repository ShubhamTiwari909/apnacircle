#!/usr/bin/env python3
"""Fill the ApnaCircle policy drafts from placeholders.json.

Usage: python3 -I fill_policies.py <placeholders.json> <output-dir>

- Reads the numbered policy drafts in this folder (01-*.md ... 08-*.md).
- Writes filled copies to <output-dir>; the drafts are never modified.
- Reports every token that is still unfilled and every review note that is still
  inside the text, and exits with status 1 if anything is outstanding.
"""
import datetime
import json
import pathlib
import re
import sys

if len(sys.argv) != 3:
    sys.exit(__doc__)

cfg_path = pathlib.Path(sys.argv[1])
out_dir = pathlib.Path(sys.argv[2])
here = pathlib.Path(__file__).resolve().parent

cfg = {k: v for k, v in json.loads(cfg_path.read_text(encoding="utf-8")).items() if not k.startswith("_")}
domain = cfg.get("domain", "").strip()


def email(key, local):
    value = cfg.get(key, "").strip()
    if value:
        return value
    return f"{local}@{domain}" if domain else ""


values = {
    "[VERSION]": cfg.get("version", "").strip(),
    "[EFFECTIVE DATE]": cfg.get("effective_date", "").strip() or datetime.date.today().strftime("%d %B %Y"),
    "[LEGAL ENTITY]": cfg.get("legal_entity", "").strip(),
    "[REGISTERED ADDRESS]": cfg.get("registered_address", "").strip(),
    "[CONTACT EMAIL]": email("contact_email", "contact"),
    "[PRIVACY EMAIL]": email("privacy_email", "privacy"),
    "[GRIEVANCE EMAIL]": email("grievance_email", "grievance"),
    "[LEGAL REQUESTS EMAIL]": email("legal_requests_email", "legal"),
    "[GRIEVANCE OFFICER NAME]": cfg.get("grievance_officer_name", "").strip(),
    "[DESIGNATION]": cfg.get("grievance_officer_designation", "").strip(),
    "[DAYS AND HOURS]": cfg.get("grievance_hours", "").strip(),
    "[JURISDICTION]": cfg.get("jurisdiction", "").strip(),
}

out_dir.mkdir(parents=True, exist_ok=True)
unfilled = {}
notes = {}
files = sorted(p for p in here.glob("0[1-8]-*.md"))

for f in files:
    text = f.read_text(encoding="utf-8")
    for token, val in values.items():
        if val:
            text = text.replace(token, val)
    left = sorted(set(t for t in values if t in text))
    if left:
        unfilled[f.name] = left
    n_notes = len(re.findall(r"\[(?:Counsel|Owner)[^\]]*\]", text)) + (1 if "**DRAFT" in text else 0)
    if n_notes:
        notes[f.name] = n_notes
    (out_dir / f.name).write_text(text, encoding="utf-8")

print(f"Wrote {len(files)} files to {out_dir}")
if unfilled:
    print("\nUNFILLED TOKENS (do not publish):")
    for name, toks in unfilled.items():
        print(f"  {name}: {', '.join(toks)}")
if notes:
    print("\nREVIEW NOTES / DRAFT BANNERS STILL IN TEXT (counsel must clear, then delete before publishing):")
    for name, n in notes.items():
        print(f"  {name}: {n}")
sys.exit(1 if (unfilled or notes) else 0)
