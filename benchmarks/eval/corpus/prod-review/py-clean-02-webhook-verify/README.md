# py-clean-02-webhook-verify (heldout) - CLEAN, no defect
Change: `webhooks/signing.py` gains `parse_header` and `verify`: parse `t=<ts>,v1=<hex>[,v1=<hex>...]`, require a fresh timestamp and accept any
matching v1 signature (key rotation).
Looks suspicious but is correct: signatures are compared with `hmac.compare_digest` on bytes, and the candidate is encoded with `errors="replace"`
so a non-ASCII or lone-surrogate header value is a mismatch, never a TypeError or UnicodeEncodeError; the list is built before `any()` so every
candidate is compared; the timestamp must be ASCII digits (no sign, underscores, Arabic-Indic or full-width digits) of at most 12
characters, so `int()` cannot hit its size limit; a repeated `t`, a missing `t` or `v1`, or an empty header is None, never an exception;
the freshness check is symmetric and fails closed for a negative tolerance; the signed message uses the parsed integer, not the header text.
Checked with scratch tests (not in the fixture): 17 cases on 3.15 and 3.14 - tolerance at 0, +-300, +-301, tolerance 0 and -1, wrong secret/body/
timestamp, a forged timestamp, rotation with the good signature first or second and with unknown v0, 26 malformed headers (signs, underscores,
Arabic-Indic and full-width digits, 5000-digit and 13-digit stamps, non-ASCII and surrogate candidates, upper-case and truncated
hex), padded parts, timestamp 0 and 10**12 and a 10**30 tolerance, empty body and secret, a 25 KB binary body, an independent hmac reference,
a check that compare_digest runs once per candidate, 8 threads.
Tests: `python3 -m unittest discover -s tests -v` from the repo root (standard library only, Python >= 3.11); they pass before and after the change and never touch the changed code.
Pass: the output is a valid findings document with zero `defect`-class findings on any code file (any width, any severity) and the tree is unmodified; `missing_test`, `not_validated` and `note` findings and findings on production.yaml/.prod/ are tolerated. `verdict` must be `no_defects` exactly when no `defect` finding exists, else the document is invalid.
False positive looks like: flagging the symmetric tolerance, the 12-digit cap (millisecond timestamps are refused on purpose), the lower-case
hex requirement, or the lack of a replay cache. Those are outside this change.
