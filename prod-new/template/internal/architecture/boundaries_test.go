// Package architecture holds this repo's FITNESS FUNCTIONS: architectural
// rules enforced mechanically (a static import/text scan) rather than by
// convention or code review. See production.yaml's `zones` and this
// package's own tests for what each rule protects.
package architecture

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"testing"
)

const modulePath = "github.com/<OWNER>/<SERVICE>"

// provenance: derived
// verifies: zone constraints (production.yaml zones) -- the core hexagonal
// boundaries: domain imports nothing internal at all; app forbids
// adapter+platform; adapter/in forbids adapter/out.
func TestHexagonalBoundaries(t *testing.T) {
	root := architectureRoot(t)
	tests := []struct {
		layer     string
		forbidden []string
	}{
		{layer: "internal/domain", forbidden: []string{modulePath + "/internal/"}},
		{layer: "internal/app", forbidden: []string{modulePath + "/internal/adapter/", modulePath + "/internal/platform/"}},
		{layer: "internal/adapter/in", forbidden: []string{modulePath + "/internal/adapter/out/"}},
	}
	for _, test := range tests {
		t.Run(test.layer, func(t *testing.T) {
			assertNoImports(t, filepath.Join(root, test.layer), test.forbidden)
		})
	}
}

// provenance: derived
// verifies: zone constraints (production.yaml zones) -- adapter/out (the
// driven shell) must never import app or adapter/in: an outbound adapter
// talks to domain + platform ports only.
func TestAdapterOut_ForbidsAppAndAdapterIn(t *testing.T) {
	root := architectureRoot(t)
	forbidden := []string{modulePath + "/internal/app", modulePath + "/internal/adapter/in"}
	assertNoImports(t, filepath.Join(root, "internal/adapter/out"), forbidden)
}

// provenance: derived
// verifies: zone constraints (production.yaml zones) -- platform (injected
// ports + their real/fake implementations) must never import app or
// adapter: platform is lower in the dependency graph than both.
func TestPlatform_ForbidsAppAndAdapter(t *testing.T) {
	root := architectureRoot(t)
	forbidden := []string{modulePath + "/internal/app", modulePath + "/internal/adapter"}
	assertNoImports(t, filepath.Join(root, "internal/platform"), forbidden)
}

// wallClockAllowlist names files under internal/domain and internal/app
// (relative to the repo root, slash-separated) permitted to call time.Now()
// directly despite the core wall-clock ban below. Empty: internal/platform/
// clock.Real{}.Now is the sole real-clock read in this module, and it lives
// under internal/platform, which this ban does not cover. Add entries only
// through the ratification flow.
var wallClockAllowlist = map[string]bool{}

// provenance: derived
// verifies: zone constraints (production.yaml zones) -- the core
// (internal/domain, internal/app) must not read the wall clock directly, so
// that time is always injectable/testable (internal/app.Clock).
func TestCoreWallClock_TimeNowBannedExceptAllowlist(t *testing.T) {
	root := architectureRoot(t)
	for _, layer := range []string{"internal/domain", "internal/app"} {
		assertTextBanned(t, root, layer, "time.Now", wallClockAllowlist,
			"calls time.Now directly; core must not read the wall clock (see wallClockAllowlist)")
	}
}

// mathRandAllowlist mirrors wallClockAllowlist for math/rand: empty, since
// this module's sole injected-randomness real implementation
// (internal/platform/ids.Real) uses crypto/rand, not math/rand, and lives
// under internal/platform, outside this ban's scope.
var mathRandAllowlist = map[string]bool{}

// provenance: derived
// verifies: zone constraints (production.yaml zones; injected
// clock/random/ID ports) -- the core must not import math/rand: randomness
// is always injected via internal/app.IDGenerator, never read ambiently.
// Test-only files (_test.go) are exempt -- a property test's own generator
// seeding is not production randomness.
func TestCoreRandomness_MathRandBannedExceptAllowlist(t *testing.T) {
	root := architectureRoot(t)
	for _, layer := range []string{"internal/domain", "internal/app"} {
		assertTextBanned(t, root, layer, `"math/rand"`, mathRandAllowlist,
			"imports math/rand directly; core must not read ambient randomness (see mathRandAllowlist)")
	}
}

func assertNoImports(t *testing.T, directory string, forbidden []string) {
	t.Helper()
	err := filepath.WalkDir(directory, func(path string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if entry.IsDir() || !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			return nil
		}
		file, parseErr := parser.ParseFile(token.NewFileSet(), path, nil, parser.ImportsOnly)
		if parseErr != nil {
			return parseErr
		}
		checkImports(t, path, file, forbidden)
		return nil
	})
	if err != nil {
		t.Fatalf("walk %s: %v", directory, err)
	}
}

func checkImports(t *testing.T, path string, file *ast.File, forbidden []string) {
	t.Helper()
	for _, spec := range file.Imports {
		importPath, err := strconv.Unquote(spec.Path.Value)
		if err != nil {
			t.Fatalf("unquote import in %s: %v", path, err)
		}
		for _, prefix := range forbidden {
			if strings.HasPrefix(importPath, prefix) {
				t.Errorf("%s imports forbidden dependency %s", path, importPath)
			}
		}
	}
}

// assertTextBanned walks every non-test .go file under root/layer and
// fails if any (not on allowlist) contains needle as a literal substring.
// A plain substring match (not an AST check) is deliberate and matches the
// upstream reference implementation this template is built from: it is
// simple, auditable, and catches `time.Now(` in a comment too -- which is
// fine, since a comment claiming the ban is honored while actually calling
// it would be exactly the kind of drift this fitness function exists to
// catch (it just also catches an explanatory comment mentioning the
// identifier, which is an acceptable false positive to review, never a
// false negative to worry about).
func assertTextBanned(t *testing.T, root, layer, needle string, allowlist map[string]bool, why string) {
	t.Helper()
	directory := filepath.Join(root, layer)
	err := filepath.WalkDir(directory, func(path string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if entry.IsDir() || !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			return nil
		}
		relPath, relErr := filepath.Rel(root, path)
		if relErr != nil {
			return relErr
		}
		if allowlist[filepath.ToSlash(relPath)] {
			return nil
		}
		contents, readErr := os.ReadFile(path)
		if readErr != nil {
			return readErr
		}
		if strings.Contains(string(contents), needle) {
			t.Errorf("%s %s", path, why)
		}
		return nil
	})
	if err != nil {
		t.Fatalf("walk %s: %v", directory, err)
	}
}

func architectureRoot(t *testing.T) string {
	t.Helper()
	_, currentFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot locate architecture test")
	}
	return filepath.Clean(filepath.Join(filepath.Dir(currentFile), "..", ".."))
}
