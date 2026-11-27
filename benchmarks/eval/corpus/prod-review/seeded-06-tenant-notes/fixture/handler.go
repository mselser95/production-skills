package notes

import (
	"encoding/json"
	"io"
	"net/http"
)

// TenantHeader names the request header that carries the caller's tenant.
const TenantHeader = "X-Tenant"

// Handler returns the notes API. Every route requires a tenant, and a tenant
// only ever sees its own notes; another tenant's note reads as not found.
func Handler(s *Store) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /notes/{id}", func(w http.ResponseWriter, r *http.Request) {
		tenant := r.Header.Get(TenantHeader)
		if tenant == "" {
			http.Error(w, "tenant required", http.StatusUnauthorized)
			return
		}
		n, ok := s.Get(r.PathValue("id"))
		if !ok || n.Tenant != tenant {
			http.Error(w, "not found", http.StatusNotFound)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(n)
	})
	mux.HandleFunc("PUT /notes/{id}", func(w http.ResponseWriter, r *http.Request) {
		tenant := r.Header.Get(TenantHeader)
		if tenant == "" {
			http.Error(w, "tenant required", http.StatusUnauthorized)
			return
		}
		body, err := io.ReadAll(io.LimitReader(r.Body, 4096))
		if err != nil {
			http.Error(w, "bad body", http.StatusBadRequest)
			return
		}
		id := r.PathValue("id")
		if old, ok := s.Get(id); ok && old.Tenant != tenant {
			http.Error(w, "not found", http.StatusNotFound)
			return
		}
		s.Put(Note{ID: id, Tenant: tenant, Body: string(body)})
		w.WriteHeader(http.StatusNoContent)
	})
	return mux
}
