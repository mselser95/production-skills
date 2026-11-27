#!/usr/bin/env bash
# sha256.sh -- sourced. eval_sha256: stdin -> hex digest (sha256sum on Linux, shasum on macOS).
eval_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -c1-64
  else shasum -a 256 | cut -c1-64
  fi
}
