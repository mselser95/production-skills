# .prod/evidence — one record per commit

`scripts/verify-standard.sh` writes `<sha>.json` here on every run: policy
version implied by the probe's own dimensions, every gate's PASS/FAIL/NA
verdict, and totals. This answers "under what standard was this commit
held?" later without archaeology (tier-policy.yaml: `evidence_record:
required`). Nothing here is hand-authored — it is the probe's own output.
