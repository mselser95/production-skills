package buildinfo

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime/debug"
	"strings"
	"testing"
)

// provenance: derived
// verifies: operational determinism (Output = F(code, config, state,
// inputs), all versioned)
func TestGet_NeverPanicsAndSurfacesGoVersion(t *testing.T) {
	info := Get()
	if info.GoVersion == "" {
		t.Fatalf("Get() = %+v, want a non-empty GoVersion", info)
	}
}

// provenance: derived
// verifies: operational determinism
func TestInfoFrom_NoVCSSettings_FallsBackToLdflagsValues(t *testing.T) {
	bi := &debug.BuildInfo{GoVersion: "go1.26"}
	got := infoFrom(bi, true, "abc123", "2026-08-17T00:00:00Z")
	if got.Revision != "abc123" || got.BuildTime != "2026-08-17T00:00:00Z" || got.GoVersion != "go1.26" {
		t.Fatalf("got=%+v, want fallback revision/buildtime + real go version", got)
	}
}

// provenance: derived
// verifies: operational determinism
func TestInfoFrom_VCSSettingsPresent_PreferReadBuildInfoOverFallback(t *testing.T) {
	bi := &debug.BuildInfo{
		GoVersion: "go1.26",
		Main:      debug.Module{Version: "v1.2.3"},
		Settings: []debug.BuildSetting{
			{Key: "vcs.revision", Value: "deadbeef"},
			{Key: "vcs.time", Value: "2026-08-17T16:18:08Z"},
			{Key: "vcs.modified", Value: "true"},
		},
	}
	got := infoFrom(bi, true, "should-be-overridden", "should-be-overridden-too")
	if got.Revision != "deadbeef" || got.BuildTime != "2026-08-17T16:18:08Z" || !got.Modified || got.ModuleVersion != "v1.2.3" {
		t.Fatalf("got=%+v, want ReadBuildInfo values to win", got)
	}
}

// provenance: derived
// verifies: operational determinism
func TestInfoFrom_NotOK_FallsBackToLdflagsValues(t *testing.T) {
	got := infoFrom(nil, false, "fallback-rev", "fallback-time")
	if got.Revision != "fallback-rev" || got.BuildTime != "fallback-time" {
		t.Fatalf("got=%+v, want fallback values with ok=false", got)
	}
	if got.GoVersion != "" || got.ModuleVersion != "" {
		t.Fatalf("got=%+v, want empty GoVersion/ModuleVersion when ReadBuildInfo failed", got)
	}
}

// provenance: derived
// verifies: operational determinism
func TestInfoFrom_EmptyVCSValueDoesNotOverrideFallback(t *testing.T) {
	bi := &debug.BuildInfo{
		Settings: []debug.BuildSetting{
			{Key: "vcs.revision", Value: ""},
			{Key: "vcs.time", Value: ""},
		},
	}
	got := infoFrom(bi, true, "fallback-rev", "fallback-time")
	if got.Revision != "fallback-rev" || got.BuildTime != "fallback-time" {
		t.Fatalf("got=%+v, want the fallback preserved", got)
	}
}

// provenance: derived
// verifies: operational determinism (prod-review-class check: revision must
// be NON-EMPTY in the artifact that reaches production, not merely wired) --
// builds the real cmd binary and reads the VCS stamp back off it, exactly
// like the image build would.
func TestBuiltBinary_CarriesANonEmptyVCSRevision(t *testing.T) {
	root := repoRootForTest(t)
	out := filepath.Join(t.TempDir(), "svc")

	build := exec.Command("go", "build", "-o", out, "./cmd/<SERVICE>")
	build.Dir = root
	if combined, err := build.CombinedOutput(); err != nil {
		t.Fatalf("go build ./cmd/<SERVICE>: %v\n%s", err, combined)
	}

	if info, statErr := os.Stat(filepath.Join(root, ".git")); statErr == nil && !info.IsDir() {
		t.Skip("git worktree checkout: -buildvcs cannot stamp here (.git is a file); TestDockerignore_DoesNotExcludeGitWithoutAnLdflagsPath guards this everywhere else")
	}
	if _, statErr := os.Stat(filepath.Join(root, ".git")); statErr != nil {
		t.Skip("no .git directory present in this checkout (e.g. the template was copied without git init yet) -- -buildvcs has nothing to stamp")
	}

	stamp := exec.Command("go", "version", "-m", out)
	stamp.Dir = root
	combined, err := stamp.CombinedOutput()
	if err != nil {
		t.Fatalf("go version -m: %v\n%s", err, combined)
	}
	if !strings.Contains(string(combined), "vcs.revision=") {
		t.Fatalf("the built binary carries no vcs.revision stamp -- every image would ship revision=\"\".\ngo version -m said:\n%s", combined)
	}
}

// provenance: derived
// verifies: operational determinism (the .dockerignore condition that would
// empty revision if .git were ever excluded)
func TestDockerignore_DoesNotExcludeGitWithoutAnLdflagsPath(t *testing.T) {
	root := repoRootForTest(t)
	data, err := os.ReadFile(filepath.Join(root, ".dockerignore"))
	if err != nil {
		t.Fatalf("read .dockerignore: %v", err)
	}
	for _, line := range strings.Split(string(data), "\n") {
		if strings.TrimSpace(line) == ".git" {
			dockerfile, dErr := os.ReadFile(filepath.Join(root, "docker", "Dockerfile"))
			if dErr != nil || !strings.Contains(string(dockerfile), "GIT_SHA") {
				t.Fatal(".dockerignore excludes .git and docker/Dockerfile has no GIT_SHA ldflags path: every built image would ship an empty revision")
			}
		}
	}
}

func repoRootForTest(t *testing.T) string {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	for range 6 {
		if _, statErr := os.Stat(filepath.Join(dir, "go.mod")); statErr == nil {
			return dir
		}
		dir = filepath.Dir(dir)
	}
	t.Fatal("could not locate the repo root")
	return ""
}
