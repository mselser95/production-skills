#!/usr/bin/env bash
# Applies the change under review as an uncommitted modification.
# Run with cwd = a git repo whose single commit is fixture/.
set -eu
git apply --whitespace=nowarn <<'PATCH_EOF'
diff --git a/handler.go b/handler.go
index d902a1b..bf2e3c0 100644
--- a/handler.go
+++ b/handler.go
@@ -46,5 +46,21 @@ func Handler(s *Store) http.Handler {
 		s.Put(Note{ID: id, Tenant: tenant, Body: string(body)})
 		w.WriteHeader(http.StatusNoContent)
 	})
+	// DELETE /notes/{id} removes a note and answers 204.
+	mux.HandleFunc("DELETE /notes/{id}", func(w http.ResponseWriter, r *http.Request) {
+		// The tenant comes from the request header, as in the other routes.
+		tenant := r.Header.Get(TenantHeader)
+		if tenant == "" {
+			http.Error(w, "tenant required", http.StatusUnauthorized)
+			return
+		}
+		// A note that is not there is a 404.
+		n, ok := s.Delete(r.PathValue("id"))
+		if !ok || n.Tenant != tenant {
+			http.Error(w, "not found", http.StatusNotFound)
+			return
+		}
+		w.WriteHeader(http.StatusNoContent)
+	})
 	return mux
 }
PATCH_EOF
