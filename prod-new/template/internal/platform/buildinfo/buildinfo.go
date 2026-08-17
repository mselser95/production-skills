// Package buildinfo surfaces this process's build identity -- git revision,
// build time, and Go toolchain version.
//
// This is one leg of the operational-determinism contract: production
// output is F(code, config, state, inputs), and all four must be versioned
// or a replay can never be tied to what actually produced a result. This
// package answers the "commit X" half; internal/platform/config answers
// "config Y" (see Config.Digest/Config.Identity).
//
// runtime/debug.ReadBuildInfo() (stdlib, zero new dependency) is the
// PRIMARY source: a plain `go build` (Go >=1.18, run inside a git checkout)
// stamps vcs.revision/vcs.time/vcs.modified automatically. docker/Dockerfile
// copies the source into the image WITHOUT .git (see .dockerignore's own
// comment for why -- .git is deliberately kept, unlike a naive
// .dockerignore), but if that ever changes, -ldflags -X is the documented
// fallback path: Get() prefers ReadBuildInfo's answer whenever it has one
// and only falls back to the linker-injected values otherwise.
package buildinfo

import "runtime/debug"

// Set via `-ldflags "-X .../buildinfo.ldRevision=<sha> -X
// .../buildinfo.ldBuildTime=<RFC3339>"` in docker/Dockerfile's build RUN
// step, IF the build context ever stops including .git. Both stay their
// zero value ("") for a plain `go build`/`go test`, where Get() has a real
// answer from ReadBuildInfo instead.
var (
	ldRevision  string
	ldBuildTime string
)

// Info is this process's build identity.
type Info struct {
	// Revision is the git commit SHA this binary was built from. Empty if
	// neither VCS stamping nor -ldflags supplied one.
	Revision string
	// Modified is true when ReadBuildInfo reports the working tree carried
	// uncommitted changes at build time.
	Modified bool
	// BuildTime is when this binary was built (RFC3339 from vcs.time).
	BuildTime string
	// GoVersion is the toolchain that produced this binary.
	GoVersion string
	// ModuleVersion is the main module's version if this binary carries
	// one. "(devel)" is Go's own answer for an ordinary in-module `go
	// build` and is kept as-is -- it IS the accurate answer for that build
	// path.
	ModuleVersion string
}

// Get reads this process's build identity. Cheap and side-effect-free;
// callers that need this on every /healthz request or every span are
// expected to call it once at composition-root time and reuse the result.
func Get() Info {
	bi, ok := debug.ReadBuildInfo()
	return infoFrom(bi, ok, ldRevision, ldBuildTime)
}

func infoFrom(bi *debug.BuildInfo, ok bool, fallbackRevision, fallbackBuildTime string) Info {
	info := Info{Revision: fallbackRevision, BuildTime: fallbackBuildTime}
	if !ok || bi == nil {
		return info
	}
	info.GoVersion = bi.GoVersion
	if bi.Main.Version != "" {
		info.ModuleVersion = bi.Main.Version
	}
	for _, s := range bi.Settings {
		switch s.Key {
		case "vcs.revision":
			if s.Value != "" {
				info.Revision = s.Value
			}
		case "vcs.time":
			if s.Value != "" {
				info.BuildTime = s.Value
			}
		case "vcs.modified":
			info.Modified = s.Value == "true"
		}
	}
	return info
}
