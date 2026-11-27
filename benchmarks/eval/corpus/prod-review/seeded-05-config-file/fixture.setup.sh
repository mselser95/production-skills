#!/usr/bin/env bash
# Applies the change under review as an uncommitted modification.
# Run with cwd = a git repo whose single commit is fixture/.
set -eu
git apply --whitespace=nowarn <<'PATCH_EOF'
diff --git a/config.go b/config.go
index 23b8e9c..d97076b 100644
--- a/config.go
+++ b/config.go
@@ -7,6 +7,7 @@ import (
 	"errors"
 	"fmt"
 	"io"
+	"io/fs"
 	"strconv"
 	"strings"
 	"time"
@@ -69,3 +70,27 @@ func set(c *Config, key, val string) error {
 	}
 	return nil
 }
+
+// LoadFile reads the settings file name from fsys, then applies environment
+// overrides through getenv. A missing file is not an error: the defaults are
+// used, so a service can run from the environment alone.
+func LoadFile(fsys fs.FS, name string, getenv func(string) string) (Config, error) {
+	cfg := Defaults()
+	f, err := fsys.Open(name)
+	switch {
+	case err == nil:
+		cfg, err = Parse(f)
+		if err != nil {
+			return Config{}, fmt.Errorf("parse %s: %w", name, err)
+		}
+		if err := f.Close(); err != nil {
+			return Config{}, fmt.Errorf("close %s: %w", name, err)
+		}
+	case !errors.Is(err, fs.ErrNotExist):
+		return Config{}, fmt.Errorf("open %s: %w", name, err)
+	}
+	if err := ApplyEnv(&cfg, getenv); err != nil {
+		return Config{}, fmt.Errorf("env: %w", err)
+	}
+	return cfg, nil
+}
PATCH_EOF
