# Go service practices as CI-gate checks (researched 2026-11-27)

Format: PRACTICE -> why -> gate (command/config) -> source [S#, see SOURCES].
Quotes are as returned by the fetch tool (a summarising model sat between me and the page), so
treat wording as near-verbatim; see UNVERIFIED. "[non-primary]" marks non-primary evidence.
Versions/dates below are what the pages showed on 2026-11-27.

## 1. Toolchain and build

1.1 Run a supported Go. Why: security fixes go only to the two newest majors. Gate: CI pins `go-version` and a check compares `go.mod` `go` line / `go env GOVERSION` to the supported list.
  - Current: go1.27.0 (2026-08-19), latest minor go1.27.4 (2026-11-10); go1.26.11 (2026-11-10). [S1]
  - Policy: "Each major Go release is supported until there are two newer major releases." [S1] => 1.25 and older are EOL today.
  - Security fixes: "Fixes are prepared for the two most recent major releases and the head/master revision." [S2] Minors ship ~monthly; PRIVATE-track fixes wait for them.
1.2 Declare `go` as the true minimum, treat `toolchain` as a suggestion. Gate: `go mod tidy -diff` (non-zero on drift, per cmd/go [S5]); lint that `go` line <= CI Go version.
  - "The `go` line declares the minimum required Go version for using the module or workspace." [S3]
  - "The `toolchain` line declares a suggested toolchain to use with the module or workspace." [S3]
  - Since 1.25 go no longer adds a toolchain line when it bumps `go`: "it no longer adds a toolchain line specifying the command's current version." [S4] Old advice "always commit a toolchain line" is stale.
1.3 CI sets `GOTOOLCHAIN=local` (hermetic, no surprise downloads) or accepts `auto` knowingly. Why: `auto` = `local+auto`, "the go command selects and runs a newer Go version as needed." [S3] Downloads are checksum-verified but "toolchain downloads fail for lack of verification if GOSUMDB=off." [S3] Gate: `test "$(go env GOTOOLCHAIN)" = local` in the build image.
1.4 Reproducible builds. Why: lets a third party rebuild and compare. Gate: build twice (different dirs) with `CGO_ENABLED=0 go build -trimpath -buildvcs=true` and compare `sha256sum`.
  - "For Go programs that don't need cgo, a reproducible build is as simple as compiling with CGO_ENABLED=0 go build -trimpath." [S6]; toolchain itself reproducible since 1.21.0 [S6].
  - With cgo you must pin the host C toolchain (container digest) [S6].
  - `-buildvcs`: true/false/auto(default) stamps VCS info; `-trimpath` removes fs paths [S5]. Verify stamping: `go version -m ./bin/svc | grep -E 'vcs.revision|-trimpath'` (go version -m is my knowledge, not fetched).
1.5 Static linking for scratch/distroless-static: `CGO_ENABLED=0`; gate `file bin/svc | grep -q 'statically linked'` or `go version -m` shows `CGO_ENABLED=0` (build setting; not fetched, UNVERIFIED exact output).
1.6 Build tags for lanes (`integration`, `e2e`): tests must stay hermetic by default. Gate: `go vet -tags integration ./...` and `go test -tags integration -run xxx ./...` compile-check each lane so a tagged lane cannot rot silently. `-tags` is also a govulncheck flag [S8]. Source for tag semantics: not fetched, UNVERIFIED.
1.7 Module mode: CI uses `-mod=readonly` (default since 1.16: "if any changes to go.mod are needed, the go command reports an error" [S7]) or vendoring. Vendor: "If the vendor directory is present ... it will be used automatically" for go >= 1.14 [S7]; consistency with go.mod is checked [S7]. Gate: `go mod tidy -diff` + `go mod vendor && git diff --exit-code vendor` + `go mod verify`. NOTE `go mod verify` "does not use go.sum files to verify module content" [S7] - it checks the local cache against its own recorded hash; the real authenticity chain is go.sum + sum.golang.org.
1.8 Private modules: `GOPRIVATE` "Acts as a default value for GONOPROXY and GONOSUMDB" [S7]. Pitfall: for private or `GOSUMDB=off` modules the go command "accepts the hash and adds the file to the module cache without verifying it." [S7] Scope GOPRIVATE to your own org prefix only; never `GONOSUMDB=*`/`GOSUMDB=off` globally. Gate: `go env GONOSUMDB GOPRIVATE GOSUMDB GOFLAGS GOINSECURE` allow-list check; fail on `GOSUMDB=off`, on `GOINSECURE` set, or on `GOFLAGS=-mod=mod`.
1.9 `replace` directives are unauthenticated: "Go tools don't authenticate external modules" under replace [S9]. Gate: `go mod edit -json | jq '.Replace'` must be empty on release branches (local-path replaces banned).
1.10 Tool dependencies live in go.mod via `tool` directives (Go 1.24+): "you can add a tool dependency with: go get -tool ..." [S9]; run `go tool <name>`. Gate: no `go install x@latest` in CI; tools pinned in go.mod so go.sum covers them. Older `tools.go` blank-import trick is superseded (my inference from [S9],[S10]).

## 2. Dependencies and supply chain

2.1 govulncheck on every PR AND on a schedule (new CVEs land without code changes). Why: reachability analysis cuts noise: "only surfaces vulnerabilities that actually affect you". [S8][S11]
  - Source mode `govulncheck ./...`: exits non-zero when vulns found; "exits successfully for JSON, SARIF, and OpenVEX output, regardless of how many vulnerabilities are detected" [S8] => a gate using `-format json|sarif` MUST parse findings itself or it is vacuous. Same trap in golang/govulncheck-action: "Specifying the output format 'json' or 'sarif' will return success even if there are some vulnerabilities detected." [S12]
  - Binary mode `govulncheck -mode binary ./bin/svc` scans what shipped; "may report false positives for code that is in the binary but unreachable", no call stacks; pre-1.18 binaries only stdlib. [S8]
  - Blind spots: reflect-only reach is not reported, `unsafe` may cause false negatives, no suppression mechanism [S8]; only DB-listed vulns (vulns in installable commands may be excluded) [S11]; not a licence or malware scanner. Pair with 2.2.
  - Flags: `-test`, `-tags`, `-show traces|verbose`, `-db` [S8]. Go stdlib vulns are reported against the toolchain you run, so the scan Go version must equal the build Go version.
2.2 Review dependency updates; "Updating to the latest versions without thorough review can also be risky, potentially introducing new bugs, incompatible changes, or even malicious code." [S10] Gate: Dependabot or Renovate PRs + required CI; a policy check that new modules need approval (diff of `go list -m all`). Scorecard check `Dependency-Update-Tool`: "Out-of-date dependencies make a project vulnerable" [S13].
2.3 Currency: `go list -m -u all` lists available updates [S9]; gate = count of modules with `Update` in `go list -m -u -json all` above threshold (age policy is yours; no primary source sets a number).
2.4 Licences: no Go-toolchain mechanism. `cyclonedx-gomod ... -licenses` does detection [S14]; or `go-licenses` (google/go-licenses; not fetched, UNVERIFIED). Gate: SBOM licence list vs allow-list.
2.5 SBOM per release artifact.
  - `cyclonedx-gomod`: modes `app` ("only those modules that the target application actually depends on"), `mod`, `bin` ("rudimentary SBOMs from binaries"); `-licenses`, `-json`, `-std` [S14]. Needs Go 1.26+ to build [S14].
  - `syft <image> -o cyclonedx-json` (formats CycloneDX, SPDX) [S15]. Release dates not shown by either page. Gate: SBOM file exists, parses, contains the main module and every `go.sum` module for the shipped binary.
2.6 Signed artifacts + provenance. SLSA v1.1: L1 "Automatically generate provenance"; L2 hosted platform, "Prevents tampering after the build through digital signatures"; L3 "prevent secret material used to sign the provenance from being accessible to the user-defined build steps." [S16] Realistic target for a service: L2, L3 via reusable workflow.
  - GitHub artifact attestations: "unfalsifiable provenance and integrity guarantees"; alone = Build L2, a shared reusable workflow can reach L3; verify with `gh attestation verify ...` [S17].
  - `slsa-framework/slsa-github-generator` (Go builder) page banner: "no longer actively maintained"; last release v2.1.0 Feb 2025; page suggests GitHub attestations instead [S18]. SUPERSEDED for new setups.
  - cosign keyless: "Keyless signing associates identities, rather than keys, with an artifact signature"; events "logged in Rekor" [S19]. Gate: `cosign verify <image> --certificate-identity=... --certificate-oidc-issuer=...` or `gh attestation verify`, run in a separate deploy-side job, failing closed.
2.7 GitHub Actions hardening (as a gate on workflows): "Pin references to actions to a commit SHA" [S20]; "make sure that the GITHUB_TOKEN is granted the minimum required permissions" [S20]; "Avoid using the pull_request_target workflow trigger if it's not necessary" [S20]; OIDC instead of long-lived secrets [S20]. Gate: OpenSSF Scorecard checks Pinned-Dependencies, Token-Permissions, Dangerous-Workflow, Signed-Releases, Binary-Artifacts [S13][S21]; `scorecard --checks=...` or ossf/scorecard-action with a minimum score (scale 0-10 per check [S13]). Also a grep gate: every `uses:` matches `@[0-9a-f]{40}`, every workflow has top-level `permissions:`.
2.8 Secure-development frame: NIST SSDF v1.1 (SP 800-218), groups PO/PS/PW/RV [S22]; the page did not show a Rev 1/v1.2 [S22]. OWASP ASVS 5.0.0 stable, "Published 30 May 2025" [S23]; OWASP Top 10:2025 is current [S24].

## 3. Static analysis

3.1 `go vet ./...` is the floor; `go test` runs a subset by default: atomic, bools, buildtag, directive, errorsas, ifaceassert, nilfunc, printf, stdversion, stringintconv, tests [S5]. Vet exit is non-zero "if a problem was reported" [S25]. Analyzers worth knowing: copylocks, lostcancel, loopclosure, httpresponse, stdversion, waitgroup, hostport, tests [S25][S4]. New: `waitgroup` "reports misplaced calls to sync.WaitGroup.Add" and `hostport` flags `fmt.Sprintf("%s:%d", host, port)` (IPv6-unsafe) in 1.25 [S4]; `go test` runs `stdversion` by default in 1.27 [S26]; printf now flags `%w` of `*E` where E is an error [S26].
3.2 staticcheck: "Just run staticcheck ./... on your code in addition to go vet ./..." [S27]; 150+ checks [S27]. Inside golangci-lint it is the `staticcheck` linter [S28]. Version/support policy not shown on the page.
3.3 golangci-lint v2 model: config must say `version: "2"` ("The only possible value is "2"") [S29]; file names `.golangci.{yml,yaml,toml,json}` [S29]; `linters.default` in {standard (default), all, none, fast} [S29]; `linters.exclusions.presets` (comments, std-error-handling, common-false-positives, legacy) [S29]; separate `formatters` section [S29]; `run.timeout`, `run.tests` (default true) [S29]; per-linter cap `issues.max-issues-per-linter` default 50 (0 = unlimited) [S29]. Latest release v2.15.0 (2026-10-16) via GitHub API [S30]. Gates: `golangci-lint config verify` and `golangci-lint run ./...` (both exist in v2; subcommand names not re-verified on the page - UNVERIFIED). Set `max-issues-per-linter: 0` or the gate silently truncates at 50.
3.4 Linters that matter (all confirmed to exist and not deprecated on [S28]): errcheck ("unchecked errors"), gosec ("source code security problems"), bodyclose, sqlclosecheck, rowserrcheck, contextcheck ("non-inherited context"), noctx, exhaustive, nilerr, forcetypeassert, errorlint (error wrapping), durationcheck, fatcontext, copyloopvar, sloglint ("consistent code style when using log/slog"), forbidigo, depguard (import allow-list = domain-boundary gate), paralleltest, tparallel, thelper, testifylint, usetesting, nilnil, makezero, gocritic, revive. gomodguard is deprecated ("Use gomodguard_v2 instead", since v2.12.0) [S28]. The page did not show which are in `standard`; check `golangci-lint help linters`. Realistic yield: errcheck/bodyclose/sqlclosecheck/rowserrcheck/noctx/contextcheck = resource & context leaks; exhaustive = missing enum cases; errorlint = broken `errors.Is/As`; depguard = enforce layering.
3.5 gosec (securego): rule families G1xx general (hardcoded creds, unsafe, HTTP hardening), G2xx injection, G3xx file/path, G4xx crypto/TLS, G5xx blocklisted imports, G6xx Go-specific, G7xx TAINT rules (SQLi, command injection, path traversal, SSRF, XSS, log injection, unsafe deserialization, open redirect) [S31]. Formats incl. sarif; `-severity medium`, `-confidence`, `-exclude=Gxxx`; `#nosec [RuleList] -- justification`; exit 1 on any finding, `-no-fail` forces 0 [S31]. Gate: `gosec -severity medium -confidence medium -fmt sarif -out gosec.sarif ./...`; separately ban bare `#nosec` without rule+justification via grep.
3.6 Dataflow SAST. CodeQL: Go supported; "You can use CodeQL to track the flow of data through a Go program to its use." [S32] Build modes and suite names (default/security-extended) were not confirmed on fetched pages (UNVERIFIED). Semgrep: "Semgrep CE only performs single-function taint analysis"; interfile taint is Pro (paid) [S33]. Realistic: CodeQL finds source->sink flows across functions/packages (SQLi, SSRF, path traversal); semgrep CE finds pattern/intra-function issues and custom house rules; gosec G7xx gives a cheap taint pass. Gate: CodeQL SARIF with zero open alerts >= medium via code-scanning required check (GitHub setting).

## 4. Testing

4.1 Core flags (cmd/go [S5]): `-race` ("enable data race detection"; with -race covermode becomes atomic); `-shuffle off,on,N` "Randomize the execution order of tests and benchmarks."; `-count=1` is "the idiomatic way to disable test caching"; `-timeout` default 10m; `-failfast`, `-skip`, `-json`; `-parallel`; `-cpu`. Gate: `go test -race -shuffle=on -count=1 -timeout=10m -covermode=atomic -coverprofile=c.out ./...` and print the shuffle seed so failures replay (`-shuffle=<seed>`). Security guidance: "The race detector finds races that occur at runtime, however, so it will not find races in code paths that are not executed." [S34]
4.2 Coverage: unit `go test -coverprofile`; `-coverpkg=pattern` instruments packages matching the pattern across package boundaries [S5]. Integration/e2e binaries: `go build -cover -o svc .`, run with `GOCOVERDIR=dir` ("Binaries built with -cover write out profile data files ... to a directory specified via GOCOVERDIR"), report `go tool covdata percent -i=dir`, `covdata textfmt`, `covdata merge` [S35]. "Coverage data is lost if the program ends in an unrecovered panic or a fatal signal." [S35] Statement % matches `go test -cover` [S35]. Gate: merged profile >= threshold per package (`go tool cover -func`).
4.3 Native fuzzing [S36]: `-fuzz` regex must match a single fuzz test; `-fuzztime` default forever; `-fuzzminimizetime` default 60s; seed corpus in `testdata/fuzz/FuzzX` runs under plain `go test`; generated corpus in `$GOCACHE/fuzz`; failures saved to testdata become regression tests; one target per run; arg types string/[]byte/ints/floats/bool; platforms with coverage instrumentation (AMD64, ARM64); >1s/exec "took too long". Gate (PR): plain `go test` (seeds). Gate (nightly): `go test -fuzz=FuzzX -fuzztime=60s -run=^$ ./pkg` per target, commit new `testdata/fuzz` files. The page has no CI section; the split is my inference. Scorecard `Fuzzing` check recognises Go native fuzzing [S21] (summary only).
4.4 Property-based testing: `pgregory.net/rapid` (github.com/flyingmutant/rapid): "Rapid is a Go library for property-based testing"; generics, shrinking, saved failures, state-machine tests, "any rapid test can be used as a fuzz target for the standard fuzzer" [S37]; latest v1.3.0 released 2026-04-30 (GitHub API) [S37]. Prefer it. `leanovate/gopter`: last commit 2026-04-20 [S38] (alive, older API, no generics - my knowledge). `testing/quick` is frozen in stdlib (my knowledge, UNVERIFIED).
4.5 Mutation testing - status as of today:
  - `avito-tech/go-mutesting` (fork of zimmski): not archived, pushed 2026-10-02; prints "mutation score"; NO documented threshold flag - exit codes 0/1/2 apply to `--exec` mutants only [S39][S40]. Gate = parse score from stdout.
  - `go-gremlins/gremlins`: "Gremlins is a mutation testing tool for Go", "made to work well on smallish Go modules", latest release v0.6.0 (2025-12-06), last commit 2026-03-30 [S41]; threshold flag names not confirmed (UNVERIFIED).
  - `gtramontina/ooze`: runs as `go test -tags=mutation`, last commit 2026-08-19 but no GitHub release found and pkg.go.dev showed v0.2.0 (Feb 2023) [S42]. Light maintenance; caution.
  - `zimmski/go-mutesting` itself: pkg.go.dev shows a 2021 pseudo-version [S43]; treat as unmaintained; use avito fork. Practice: scope mutation to changed packages in the PR, run nightly for the rest; gate on score floor per package.
4.6 Deterministic time/concurrency: `testing/synctest` (experiment in 1.24, GA 1.25 [S4]): `synctest.Test` runs f "in a new bubble", waits for goroutines to exit, fails on deadlock; `Wait` blocks until all bubble goroutines are "durably blocked"; fake clock [S44][S45]. Caveats: "External I/O operations ... are not durably blocking", mutex ops are not durably blocking, no `t.Run/t.Parallel` inside a bubble [S44][S45 blog, written for 1.24 - old API `synctest.Run`; the page I read lists `Test`]. 1.27 adds `synctest.Sleep` and `NewTestServer` (in-memory fake network for net/http) [S26]. Gate: `grep -rn 'time.Sleep' --include=*_test.go` budget; lint rule via forbidigo.
4.7 Goroutine leaks. `go.uber.org/goleak`: `defer goleak.VerifyNone(t)` / `goleak.VerifyTestMain(m)`; latest v1.3.0 (2023-10-24, stable v1, "No breaking changes ... before 2.0") [S46]; caveat with `t.Parallel`: use VerifyTestMain [S46]. New in runtime: `goroutineleak` pprof profile, experimental in 1.26, "now generally available" in 1.27 at `/debug/pprof/goroutineleak`; "may fail to identify leaks caused by blocking on concurrency primitives reachable through global variables" [S26][S47]. It is a runtime/prod diagnostic, not a replacement for goleak in tests.
4.8 Real dependencies: testcontainers-go "makes it simple to create and clean up container-based dependencies"; latest v0.45.0 (2026-11-05, GitHub API) [S48]. Page did not state Docker/Ryuk details (UNVERIFIED). Gate: the `integration` lane runs it in CI with a Postgres module; require non-zero test count (`go test -json | jq`) so a skipped lane is not green.
4.9 Flake control: `gotestsum --rerun-fails --rerun-fails-max-failures=10 --junitfile r.xml --jsonfile t.json` "will re-run any failed tests", default 2 attempts, skipped "when there are too many test failures" [S49]. Retrying hides races: rerun passes must be REPORTED as flakes (parse junit/json) and fail a quarantine budget. Latest release: API returned v1.13.0 (2025-09-11) [S49].
4.10 `testing.B.Loop` (1.24) replaces `for i<b.N` in benchmarks [S50]; `T.ArtifactDir` (1.26) for test outputs [S51]; `go test -json` stream for CI summaries [S5].
4.11 Golden files: stdlib has no helper; convention is `testdata/*.golden` + `-update` flag (my knowledge; no primary source found). Gate: `go test ./... && git diff --exit-code testdata`.

## 5. Concurrency and resource safety

5.1 Propagate `context.Context` everywhere; every outbound call has a deadline. `http.Client`: "A Timeout of zero means no timeout." [S52] => ban `http.Get`/`http.DefaultClient`. Gates: `noctx`, `contextcheck`, `bodyclose`, `lostcancel` (vet) [S25][S28]; forbidigo on `http.DefaultClient|http.Get|http.Post`.
5.2 `errgroup`: "A Group is a collection of goroutines working on subtasks that are part of the same overall task."; `WithContext` derived ctx "is canceled the first time a function passed to Go returns a non-nil error"; `SetLimit(n)` bounds concurrency (negative = unlimited, 0 blocks new goroutines); `TryGo` [S53]. golang.org/x/sync v0.25.0 (2026-10-15) [S53]. Gate: lint/grep that `go func` in handlers is replaced by errgroup with SetLimit (judgement; no stock linter for "unbounded goroutine"; gocritic/custom semgrep rule).
5.3 `sync.WaitGroup.Add` misuse is caught by vet `waitgroup` (1.25) [S4]; 1.27 `go fix` renames it `waitgroupgo` (use `wg.Go` pattern) [S26]. `copylocks` catches copied mutexes [S25]. Loop-variable capture is fixed by language since 1.22 (my knowledge) - `copyloopvar` linter now flags redundant copies [S28].
5.4 `http.Server` must set timeouts: `ReadHeaderTimeout` (slowloris) etc. Field docs were truncated in my fetch (UNVERIFIED quotes); gosec has a rule for missing ReadHeaderTimeout (G112, from memory). Body caps: "MaxBytesReader prevents clients from accidentally or maliciously sending a large request" [S52]; `MaxHeaderBytes` [S52]; 1.27 adds `Server.MaxHeaderValueCount` [S26]. Gate: gosec + a handler-level test that an oversized body is rejected.
5.5 Graceful shutdown: `Server.Shutdown` then `Close` fallback; `ErrServerClosed` returned after either [S52]; semantics text not fetched. Gate: e2e test sends SIGTERM mid-request and asserts completion + exit 0.
5.6 Timer channels are now unbuffered irrespective of GODEBUG (1.27) [S26]: delete old `select{case <-t.C: default:}` drain workarounds.

## 6. Security-relevant coding

6.1 Validate at the edge, allow-list. SQL: "parameterized queries when including dynamic data" and identifiers/keywords "map user choices to a strict allow-list" [S54]. Gate: gosec G201/G202/G7xx [S31]; sqlclosecheck; grep ban on `fmt.Sprintf("SELECT` in non-test code; semgrep rule.
6.2 SSRF: "Match the host against an allowlist, and build the request yourself"; "Domain allowlisting alone does not prevent DNS rebinding"; "Disable the support for the following of the redirection" ; block 169.254.169.254 and unmap IPv4-mapped forms; "Deny-lists are bypass-prone. Prefer allow-lists." [S55] Gate: custom `net.Dialer.Control` test + `CheckRedirect` returning `http.ErrUseLastResponse`; gosec G7xx SSRF [S31].
6.3 Path traversal: `os.Root` (1.24): "The new os.Root type provides the ability to perform filesystem operations within a specific directory." [S50] Blocks `..` and symlink escapes; "Root does not prevent traversal of Linux bind mounts"; some ops unsupported at 1.24; `filepath.IsLocal` (1.20) validates a relative name but sanitising alone is "not enough" if attacker controls part of the fs [S56]. Gate: gosec G3xx [S31]; ban `filepath.Join(base, userInput)` in handlers via semgrep/forbidigo.
6.4 Crypto: `crypto/rand` "Read ... never returns an error, and always fills b entirely" (1.24) [S50][S57]; `rand.Text` >=128 bits for tokens [S57]; never `math/rand` for secrets (gosec G404, from memory). `crypto/subtle. ConstantTimeCompare` "If the lengths of x and y do not match it returns 0 immediately" - length leaks; compare MACs/hashes of equal fixed length [S58]. TLS: "By default, TLS 1.2 is currently used as the minimum"; `InsecureSkipVerify` "susceptible to machine-in-the-middle attacks"; default cipher list "might change over time" so do not pin suites [S59]. Gate: gosec G401-G405, G402 (TLS), grep `InsecureSkipVerify: true` outside tests. 1.26/1.27: `ecdsa` ignores the random param; `tls.Config.Rand` deprecated (use `cryptotest.SetGlobalRandom`); PKCS#1 v1.5 encryption deprecated; `crypto/mldsa` and hybrid PQ KEMs on by default [S51][S26]. FIPS: `GOFIPS140` selects the module version (1.24) [S50].
6.5 Templates: html/template "assumes that template authors are trusted, while Execute's data parameter is not"; escaping is contextual; `template.HTML` "should come from a trusted source" [S60]. Gate: forbid `text/template` for HTML (depguard) and grep `template.HTML(`.
6.6 Deserialization: `encoding/json` is now backed by the v2 implementation in 1.27 with stricter defaults: "rejects invalid UTF-8 ... and rejects duplicate names within a JSON object" [S26]; opt-out `GOEXPERIMENT=nojsonv2`. Old advice "json silently takes duplicate keys" is outdated for 1.27. `omitzero` (1.24) [S50]. Never `encoding/gob`/`yaml.Unmarshal` into `interface{}` from untrusted peers (gosec taint rule exists [S31]).
6.7 Secrets & logs: slog `LogValuer` lets a type redact itself ("redact secret information like passwords"); `HandlerOptions.ReplaceAttr` "can ... sanitize data, or remove attributes"; "It is recommended to pass a context to an output method" (use `InfoContext`) [S61]. Go 1.27 tracebacks include pprof labels; opt-out `tracebacklabels=0` "in case goroutine labels acquire sensitive information" [S26]. Gate: `sloglint` (`no-global`, `context`, `static-msg` options exist per its purpose [S28]; option names UNVERIFIED) + gitleaks in CI + a test that logs a `Secret` type and asserts redaction. Errors: map to `apperror`-style public codes; never return `err.Error()` of DB/IO errors.
6.8 `unsafe`/cgo: gosec G103 flags unsafe (family G1xx [S31]); 1.27 `go fix` modernizer `unsafefuncs` [S26]. cgo call overhead down ~30% in 1.26 [S51] but cgo breaks static/reproducible builds (1.4). Gate: depguard deny `unsafe` and `C` imports outside an allow-listed package; `CGO_ENABLED=0` build must pass.
6.9 Integer overflow: gosec G115 (integer conversion overflow) - from memory, UNVERIFIED on a primary page. Gate: gosec enabled with G115 not excluded; fuzz arithmetic on size inputs.
6.10 Go-SCP: OWASP Go Secure Coding Practices is an Incubator project, CC BY-SA, follows the OWASP SCP quick reference; page shows no last-updated date [S62] - use as a checklist source, not as evidence of currency.
## 7. Money and numerics

7.1 Never float for money. shopspring/decimal: "Arbitrary-precision fixed-point decimal numbers in go."; float64 "can't represent numbers such as 0.1 exactly" [S63]. v1.6.0 shown as published Oct 18, 2026 [S63].
7.2 Rounding policy explicit: `Round` vs `RoundBank` (ties to even); `DivisionPrecision` default 16 applies to `Div` (use `DivRound` with explicit precision); `MaxDecodeExponent` default 10000, "Raise it only for trusted input"; `MarshalJSONWithoutQuotes` "is dangerous for decimals with many digits" - keep decimals as JSON strings [S63]. `NewFromString` keeps trailing zeros [S63] (compare with `Equal`, not struct `==`).
7.3 Alternatives (integer minor units, `math/big`) are design choices with no primary source fetched. Gate: forbidigo on `float64` in packages tagged money/domain (`depguard`/`forbidigo`) + property tests (rapid) for conservation: sum of splits == total, round-trip string<->decimal.
## 8. Observability and operations

8.1 Structured logs with `log/slog` (JSON handler, context-aware calls) [S61]. Additions: `GroupAttrs` (1.25), `MultiHandler` (1.26) [S61]. Gate: sloglint; ban `log.Print*`/`fmt.Print*` in non-main via forbidigo.
8.2 OpenTelemetry Go: traces and metrics "Stable", logs "Release candidate" [S64]. Gate: integration test asserts spans/metrics emitted via an in-memory exporter; semantic-convention naming checks via `weaver` (not fetched, UNVERIFIED).
8.3 pprof: importing `net/http/pprof` registers on `DefaultServeMux` "for the side effect"; the page carries no security warning and no separate-port guidance [S65]. Policy (mine): serve pprof only on a loopback/admin listener with its own mux; gate = test that the public mux returns 404 on `/debug/pprof/` and gosec G108 (profiling endpoint exposed; from memory). 1.27: `go tool trace -http` with only a port now binds localhost [S26].
8.4 Runtime in containers: 1.25 sets GOMAXPROCS from the cgroup CPU limit ("will default to the CPU limit if it is less than the core count"), updates it dynamically, but only if GOMAXPROCS is unset [S66][S4]. => `automaxprocs` and manual GOMAXPROCS plumbing are obsolete on Go >= 1.25 (uber-go/automaxprocs status not fetched). GOMEMLIMIT is NOT automatic: set it; rule of thumb "leave an additional 5-10% of headroom"; it is soft (GC CPU capped at ~50%); "Don't set GOGC to off with a memory limit" if memory is shared [S67]. Gate: deployment manifest check that GOMEMLIMIT = 90-95% of the memory limit; load test asserting RSS under the limit.
8.5 Health: liveness vs readiness separation, readiness gated on dependencies - no Go primary source; k8s docs not fetched (UNVERIFIED). Gate: e2e probes.
8.6 Flight recorder (1.25): `runtime/trace.FlightRecorder` ring buffer for post-hoc traces [S4]. Green Tea GC default in 1.26 ("10-40% reduction in garbage collection overhead" expected) [S51]; DWARF5 in 1.25 [S4].
## 9. Containers and runtime

9.1 Multi-stage build, minimal base, non-root, pin base by digest: "Multi-stage builds let you reduce the size of your final image."; "use USER to change to a non-root user"; "pin the image version to a specific digest" [S68].
9.2 Distroless: images "do not contain package managers, shells or any other programs"; `static-debian13` ~2 MiB; tags latest/nonroot/debug/debug-nonroot; "signed with cosign using ephemeral keyless keys" [S69]. Pair with `CGO_ENABLED=0`. Gate: hadolint/Dockerfile policy (not fetched) or `conftest`: final stage `USER` != root, `FROM` has `@sha256:`, no `apt`/`apk` in final stage; `docker run --read-only` smoke test (read-only rootfs: no primary source fetched).
9.3 Image scan: scan the built image AND the binary: `govulncheck -mode binary` [S8] plus a CVE scanner for OS layers (Trivy/Grype - not fetched, UNVERIFIED). Docker's page only references Docker Scout policy for outdated base images [S68].
9.4 Verify base-image signature before use: `cosign verify` command is on the distroless page [S69] (exact flags UNVERIFIED).
## 10. Performance

10.1 Benchmarks: `go test -run=^$ -bench=. -benchmem -count=10 ./... | tee new.txt`, compare with `benchstat old.txt new.txt`. benchstat: "should be run at least 10 times" ("at least 10, ideally 20"), prints delta, p-value, n, `~` = not significant, default alpha 0.05, geomean row [S70]. Gate: fail if any benchmark has significant (p<0.05) regression over X% in ns/op, B/op or allocs/op (parse `benchstat -format csv`; flag not verified). Shared CI runners are noisy: allocs/op and B/op are deterministic, so gate those hard and time softly (my inference).
10.2 PGO: "finds a profile named default.pgo in the main package directory"; 2-7% CPU typical in 1.21; `-pgo=auto` default in go build; `-pgo=off` disables [S71][S5]. Gate: committed default.pgo not older than N days; build with `-pgo=auto`.
10.3 Allocation regression test: `testing.AllocsPerRun` in unit tests (stdlib; my knowledge) fails on exact alloc counts.
10.4 1.27 size-specialised malloc reduces small allocs up to 30% (opt-out expected removed in 1.28) [S26] - benchmark baselines taken on <=1.26 will shift on upgrade; re-baseline.

## 11. Dimension -> Go mechanism -> gate command

| Dimension | Go mechanism | Gate |
|---|---|---|
| structural correctness/coverage | go test -cover, -coverpkg, GOCOVERDIR+covdata | `go test -race -covermode=atomic -coverprofile`; `go tool cover -func`; covdata percent |
| mutation testing | avito go-mutesting / gremlins / ooze | parse mutation score vs floor (no native threshold in go-mutesting [S40]) |
| invariants & property tests | rapid; native fuzz seeds | `go test` (seeds + rapid); nightly `-fuzz -fuzztime` |
| failure-mode scenarios | table tests + fault-injecting fakes; synctest | `go test -race -shuffle=on` |
| integration/contract | testcontainers-go, build tags | `go test -tags integration` |
| performance & capacity | `go test -bench`, benchstat | benchstat delta threshold |
| resilience & recovery | e2e kill/restart tests | scenario tests; no stdlib tool |
| observability | slog, OTel, pprof | sloglint + exporter assertion tests |
| security | govulncheck, gosec, CodeQL, vet | `govulncheck ./...`; `gosec`; code-scanning required check |
| deployability | distroless, multi-stage, digest pin | Dockerfile policy test; smoke run |
| reproducibility | `-trimpath`, CGO_ENABLED=0, `-buildvcs` | double build + sha256 compare |
| scalability | GOMAXPROCS auto (1.25+), GOMEMLIMIT | load test (no Go-native tool) |
| bounded auto-recovery | context deadlines, errgroup.SetLimit, backoff libs | tests + `noctx`/`contextcheck` |
| published contracts | proto/OpenAPI codegen | `buf breaking`, codegen `git diff --exit-code` (not fetched) |
| data lifecycle | goose/migrate + sqlc | `sqlc diff`, migration up/down test (not fetched) |
| wiring | `go build ./...`, `go vet`, deadcode (x/tools) | build + "unused exported" check (deadcode not fetched) |
| progressive delivery | none in Go | platform (Argo Rollouts/Flagger) - outside Go |
| SAST/dataflow | gosec G7xx, CodeQL, semgrep | SARIF + zero alerts |
| schema evolution | sqlc, expand/contract migrations | migration lint (not Go-specific) |
| chaos | none in stdlib | toxiproxy/chaos-mesh style tools (not fetched) |
| consumer-driven contracts | pact-go (not fetched) | provider verification job |
| SLO/error budget | OTel metrics + backend | alert rules as code; no Go gate |
| dependency currency/pinning | go.mod/go.sum, `go list -m -u`, Dependabot, tool directive | `go mod tidy -diff`, `go mod verify`, update-count budget |
| domain boundaries | depguard, internal/ packages | `golangci-lint` depguard rules; `go list -deps` import checks |
| load/stress/soak | none in stdlib | k6/vegeta/ghz (not fetched) + pprof/`goroutineleak` |
| overload/metastability | MaxBytesReader, server timeouts, errgroup limits | custom overload test; no off-the-shelf gate |
| deterministic simulation | `testing/synctest` (in-process only) | `go test` ; no FoundationDB-style simulator |

NO good off-the-shelf Go mechanism (what people do instead): mutation-score threshold gate (parse stdout/JSON); chaos
(external tools / k8s fault injection); load/soak (k6, vegeta, custom harness); overload/metastability (bespoke
load-shed tests); full deterministic simulation (synctest covers time+goroutines in one process only; network/disk
simulation is hand-rolled fakes or `NewTestServer` for HTTP [S26]); consumer-driven contracts (third-party Pact);
progressive delivery and SLOs (platform layer); licence checking (third-party); golden-file helpers (convention);
unbounded-goroutine detection (code review + custom lint); readiness semantics (convention).
## 12. What changed recently (older advice now wrong)

- Support: Go 1.25 and older are out of support as of 1.27 [S1]; "two newer major releases" rule.
- 1.24: `os.Root`, `tool` directives (replace tools.go), `testing.B.Loop`, `runtime.AddCleanup` over `SetFinalizer`, `weak`, `GOAUTH`, vet `tests` analyzer, `omitzero`, Swiss-table maps, `crypto/rand.Read` cannot fail, FIPS 140-3 [S50].
- 1.25: container-aware dynamic GOMAXPROCS (drop automaxprocs); `testing/synctest` GA; vet `waitgroup`/`hostport`; no auto `toolchain` line; `ignore` directive in go.mod; FlightRecorder; DWARF5; fixed 1.21-era nil-check-delay bug ("could incorrectly delay nil pointer checks": check err before using the result) [S4].
- 1.26: `new(expr)`; Green Tea GC default; revamped `go fix` modernizers on the vet framework; `T.ArtifactDir`; goroutine-leak profile (experimental); `ReverseProxy.Director` deprecated for `Rewrite` (SSRF/header hygiene); PKCS#1 v1.5 encryption deprecated; `go mod init` defaults to a lower `go` version; `cmd/doc` removed [S51].
- 1.27: generic methods; `encoding/json` backed by json/v2 (stricter: duplicate keys/invalid UTF-8 rejected); `goroutineleak` profile GA; vet printf `%w` of `*E`; `stdversion` vet default in `go test`; `synctest.Sleep`, `NewTestServer`; unbuffered timer channels always; HTTP/1 body auto-drain on Close; `Server.MaxHeaderValueCount`; removed GODEBUGs (`tlsrsakex`, `tls3des`, `tls10server`, `asynctimerchan`, ...); no bzr; macOS 13+ [S26].
- Tooling: golangci-lint is v2 (`version: "2"`, `linters.default`, `formatters`, `exclusions`); `gomodguard` deprecated for `gomodguard_v2` [S28][S29]. `slsa-github-generator` "no longer actively maintained" [S18]. `-fuzz` is stable since 1.18 (my knowledge). govulncheck json/sarif exit 0 trap [S8][S12].

## UNVERIFIED (could not confirm from a primary page; what I tried)

- All page text came through a summarising fetch model; quotes may differ in whitespace/wording from the source page.
- `http.Server` timeout field docs (ReadHeaderTimeout etc.) and `Shutdown` semantics: pkg.go.dev/net/http page truncated.
- `-race` platforms, `go version -m` output format, `file` static-link check, hadolint/conftest, Trivy/Grype, read-only rootfs, k8s probes, go-licenses, deadcode, buf, sqlc/goose gates, Pact, k6/vegeta/toxiproxy: not fetched; marked "not fetched".
- gosec rule numbers G112/G115/G404/G108/G103 and gosec release date: README gave only family ranges and no release date.
- sloglint option names; gremlins threshold flag names; golangci-lint `config verify` subcommand; staticcheck release/support policy (docs page lacked them); CodeQL Go build modes and query suites (two pages tried, neither listed them).
- Which linters are in golangci-lint `standard` set (page filter lost in extraction).
- benchstat has a `-confidence`-like flag: page did not mention one; `-format csv` unverified.
- Release dates: syft, cyclonedx-gomod, ooze (no GitHub release; 404), semgrep CE: not shown. pkg.go.dev "latest" pages often showed older pinned versions ("not in the latest version of its module"); I used the GitHub API where it answered.
- OWASP Top 10:2025 category names, ASVS levels/requirement counts, NIST SSDF Rev 1 status: not shown on fetched pages.
- `testing/quick` frozen, `automaxprocs` obsolescence note, golden-file convention, `testing.AllocsPerRun`: my knowledge, no fetch.
- Go-SCP currency: no date on page.

## SOURCES (URL - date shown on page; "no date shown" unless stated)

S1 https://go.dev/doc/devel/release - no date shown (entries dated up to 2026-11-10)
S2 https://go.dev/doc/security/policy - no date shown
S3 https://go.dev/doc/toolchain - no date shown
S4 https://go.dev/doc/go1.25 - Go 1.25 notes (release 2025-08-12 per S1)
S5 https://pkg.go.dev/cmd/go (Testing_flags, Build flags anchors) - no date shown
S6 https://go.dev/blog/rebuild - no date shown
S7 https://go.dev/ref/mod (also #private-modules, #authenticating) - no date shown
S8 https://pkg.go.dev/golang.org/x/vuln/cmd/govulncheck - no date shown
S9 https://go.dev/doc/modules/managing-dependencies - no date shown
S10 https://go.dev/doc/security/best-practices - no date shown
S11 https://go.dev/doc/security/vuln/ - no date shown
S12 https://github.com/golang/govulncheck-action - no date shown
S13 https://scorecard.dev/ - no date shown
S14 https://github.com/CycloneDX/cyclonedx-gomod - no date shown
S15 https://github.com/anchore/syft - no date shown
S16 https://slsa.dev/spec/v1.1/levels - no date shown
S17 https://docs.github.com/en/actions/concepts/security/artifact-attestations - no date shown
S18 https://github.com/slsa-framework/slsa-github-generator - no date shown (release v2.1.0 Feb 2025 per page)
S19 https://docs.sigstore.dev/cosign/signing/overview/ - no date shown
S20 https://docs.github.com/en/actions/reference/security/secure-use - no date shown
S21 https://github.com/ossf/scorecard/blob/main/docs/checks.md - no date shown
S22 https://csrc.nist.gov/projects/ssdf - "Updated October 06, 2026" (page, not document)
S23 https://asvs.owasp.org/ - "Published 30 May 2025"
S24 https://top10.owasp.org/ - 2025 edition label
S25 https://pkg.go.dev/cmd/vet - no date shown
S26 https://go.dev/doc/go1.27 - Go 1.27 notes (go1.27.0 2026-08-19 per S1)
S27 https://staticcheck.dev/docs/ - no date shown
S28 https://golangci-lint.run/docs/linters/ - no date shown
S29 https://golangci-lint.run/docs/configuration/file/ (and /configuration/) - no date shown
S30 https://api.github.com/repos/golangci/golangci-lint/releases/latest - v2.15.0, 2026-10-16
S31 https://github.com/securego/gosec - no date shown
S32 https://codeql.github.com/docs/codeql-language-guides/codeql-for-go/ - no date shown
S33 https://docs.semgrep.dev/languages/go - no date shown
S35 https://go.dev/doc/build-cover - no date shown
S36 https://go.dev/doc/security/fuzz/ - no date shown
S37 https://github.com/flyingmutant/rapid ; https://api.github.com/repos/flyingmutant/rapid/releases/latest - v1.3.0, 2026-04-30
S38 https://api.github.com/repos/leanovate/gopter/commits?per_page=1 - 2026-04-20
S39 https://api.github.com/repos/avito-tech/go-mutesting - pushed_at 2026-10-02, archived false
S40 https://github.com/avito-tech/go-mutesting - no date shown
S41 https://github.com/go-gremlins/gremlins ; https://api.github.com/repos/go-gremlins/gremlins/releases/latest (v0.6.0, 2025-12-06) ; .../commits (2026-03-30)
S42 https://github.com/gtramontina/ooze ; https://pkg.go.dev/github.com/gtramontina/ooze (v0.2.0, Feb 13 2023) ; .../commits (2026-08-19)
S43 https://pkg.go.dev/github.com/zimmski/go-mutesting - pseudo-version Jun 10, 2021
S44 https://pkg.go.dev/testing/synctest - no date shown (Sleep "added in Go 1.27.0")
S45 https://go.dev/blog/synctest - no date shown (written for Go 1.24 experiment)
S46 https://github.com/uber-go/goleak ; https://api.github.com/repos/uber-go/goleak/releases/latest - v1.3.0, 2023-10-24
S47 https://go.dev/doc/go1.26 (leak profile experimental) - Go 1.26 notes
S48 https://api.github.com/repos/testcontainers/testcontainers-go/releases/latest - v0.45.0, 2026-11-05 ; https://golang.testcontainers.org/
S49 https://github.com/gotestyourself/gotestsum ; API releases/latest - v1.13.0, 2025-09-11
S50 https://go.dev/doc/go1.24 - Go 1.24 notes
S51 https://go.dev/doc/go1.26 - Go 1.26 notes (go1.26.0 2026-02-10 per S1)
S52 https://pkg.go.dev/net/http#Server - no date shown (page truncated)
S53 https://pkg.go.dev/golang.org/x/sync/errgroup - v0.25.0, Oct 15, 2026
S54 https://cheatsheetseries.owasp.org/cheatsheets/SQL_Injection_Prevention_Cheat_Sheet.html - no date shown
S55 https://cheatsheetseries.owasp.org/cheatsheets/Server_Side_Request_Forgery_Prevention_Cheat_Sheet.html - no date shown
S56 https://go.dev/blog/osroot - no date shown
S57 https://pkg.go.dev/crypto/rand - no date shown
S58 https://pkg.go.dev/crypto/subtle - no date shown
S59 https://pkg.go.dev/crypto/tls#Config - no date shown (page truncated)
S60 https://pkg.go.dev/html/template - no date shown
S61 https://pkg.go.dev/log/slog - no date shown (page truncated)
S62 https://owasp.org/www-project-go-secure-coding-practices-guide/ - no date shown
S63 https://pkg.go.dev/github.com/shopspring/decimal - v1.6.0, Oct 18, 2026
S64 https://opentelemetry.io/docs/languages/go/ - no date shown
S65 https://pkg.go.dev/net/http/pprof - no date shown
S66 https://go.dev/blog/container-aware-gomaxprocs - no date shown
S67 https://go.dev/doc/gc-guide - no date shown
S68 https://docs.docker.com/build/building/best-practices/ - no date shown
S69 https://github.com/GoogleContainerTools/distroless - no date shown
S70 https://pkg.go.dev/golang.org/x/perf/cmd/benchstat - no date shown
S71 https://go.dev/blog/pgo - no date shown (Go 1.21 era)
