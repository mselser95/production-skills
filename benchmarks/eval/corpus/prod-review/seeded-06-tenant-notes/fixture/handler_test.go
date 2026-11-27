package notes

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func do(h http.Handler, method, path, tenant, body string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	if tenant != "" {
		req.Header.Set(TenantHeader, tenant)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func TestPutGet(t *testing.T) {
	h := Handler(NewStore())
	if c := do(h, "PUT", "/notes/n1", "acme", "hello").Code; c != http.StatusNoContent {
		t.Fatalf("put = %d", c)
	}
	rec := do(h, "GET", "/notes/n1", "acme", "")
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), "hello") {
		t.Fatalf("get = %d %q", rec.Code, rec.Body.String())
	}
}

func TestTenantIsolation(t *testing.T) {
	h := Handler(NewStore())
	do(h, "PUT", "/notes/n1", "acme", "secret")
	if c := do(h, "GET", "/notes/n1", "globex", "").Code; c != http.StatusNotFound {
		t.Fatalf("foreign get = %d, want 404", c)
	}
	if c := do(h, "PUT", "/notes/n1", "globex", "x").Code; c != http.StatusNotFound {
		t.Fatalf("foreign put = %d, want 404", c)
	}
	if c := do(h, "GET", "/notes/n1", "", "").Code; c != http.StatusUnauthorized {
		t.Fatalf("no tenant = %d, want 401", c)
	}
}
