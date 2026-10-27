package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
)

type fakeDB struct{ err error }

func (f fakeDB) Ping(context.Context) error { return f.err }

func newServer(db Pinger) http.Handler {
	return (&Server{Version: "server-v9.9.9", DB: db, Log: slog.New(slog.NewJSONHandler(io.Discard, nil))}).Handler()
}

func TestHealth(t *testing.T) {
	rec := httptest.NewRecorder()
	newServer(fakeDB{}).ServeHTTP(rec, httptest.NewRequest("GET", "/health", nil))
	if rec.Code != 200 {
		t.Fatalf("status %d", rec.Code)
	}
	var body struct {
		OK         bool              `json:"ok"`
		Version    string            `json:"version"`
		APIVersion int               `json:"apiVersion"`
		MinClient  map[string]string `json:"minClient"`
	}
	if err := json.NewDecoder(rec.Body).Decode(&body); err != nil {
		t.Fatal(err)
	}
	if !body.OK || body.Version != "server-v9.9.9" || body.APIVersion != 1 || body.MinClient["desktop"] == "" {
		t.Fatalf("body %+v", body)
	}
	if rec.Header().Get("X-Request-Id") == "" {
		t.Fatal("没有回传 X-Request-Id")
	}
}

func TestHealthReportsDatabaseDown(t *testing.T) {
	rec := httptest.NewRecorder()
	newServer(fakeDB{err: errors.New("down")}).ServeHTTP(rec, httptest.NewRequest("GET", "/health", nil))
	if rec.Code != 503 {
		t.Fatalf("status %d", rec.Code)
	}
}

func TestUnknownPathsUseErrorEnvelope(t *testing.T) {
	for _, path := range []string{"/api/v1/files", "/nope"} {
		rec := httptest.NewRecorder()
		req := httptest.NewRequest("GET", path, nil)
		req.Header.Set("X-Request-Id", "abc123")
		newServer(fakeDB{}).ServeHTTP(rec, req)
		var body struct {
			Error   struct{ Code string } `json:"error"`
			TraceID string                `json:"traceId"`
		}
		_ = json.NewDecoder(rec.Body).Decode(&body)
		if rec.Code != 404 || body.Error.Code != "not_found" || body.TraceID != "abc123" {
			t.Fatalf("%s：%d %+v", path, rec.Code, body)
		}
	}
}
