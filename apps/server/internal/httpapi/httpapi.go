// Package httpapi：HTTP 接口（spec/sync-api.md）。现在只有 /health；/api/v1 下的接口等协议确认后再实现。
package httpapi

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"log/slog"
	"net/http"
	"time"
)

// APIVersion：spec/sync-api.md 的协议版本
const APIVersion = 1

// MinClient：各端最低版本。只有新版客户端发布之后才提高
var MinClient = map[string]string{"desktop": "0.1.0"}

type Pinger interface {
	Ping(ctx context.Context) error
}

type Server struct {
	Version string
	DB      Pinger
	Log     *slog.Logger
}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", s.health)
	mux.HandleFunc("/api/v1/", func(w http.ResponseWriter, r *http.Request) {
		writeError(w, r, http.StatusNotFound, "not_found", "接口还没实现")
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		writeError(w, r, http.StatusNotFound, "not_found", "没有这个地址")
	})
	return s.withRequestID(s.withAccessLog(s.withRecover(mux)))
}

func (s *Server) health(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	ok := s.DB.Ping(ctx) == nil
	status := http.StatusOK
	if !ok {
		status = http.StatusServiceUnavailable
	}
	writeJSON(w, status, map[string]any{
		"ok": ok, "version": s.Version, "apiVersion": APIVersion, "minClient": MinClient,
	})
}

// MARK: 响应

type ctxKey struct{}

func traceID(r *http.Request) string {
	id, _ := r.Context().Value(ctxKey{}).(string)
	return id
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// 错误响应体（spec/sync-api.md §2）：{"error":{"code","message"},"traceId"}
func writeError(w http.ResponseWriter, r *http.Request, status int, code, message string) {
	writeJSON(w, status, map[string]any{
		"error":   map[string]string{"code": code, "message": message},
		"traceId": traceID(r),
	})
}

// MARK: 中间件

// X-Request-Id：客户端带了就沿用（只认合理长度），否则生成；响应头回传
func (s *Server) withRequestID(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id := r.Header.Get("X-Request-Id")
		if len(id) == 0 || len(id) > 64 {
			b := make([]byte, 8)
			_, _ = rand.Read(b)
			id = hex.EncodeToString(b)
		}
		w.Header().Set("X-Request-Id", id)
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), ctxKey{}, id)))
	})
}

type statusRecorder struct {
	http.ResponseWriter
	status int
	bytes  int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.status = code
	r.ResponseWriter.WriteHeader(code)
}

func (r *statusRecorder) Write(b []byte) (int, error) {
	if r.status == 0 {
		r.status = http.StatusOK
	}
	n, err := r.ResponseWriter.Write(b)
	r.bytes += n
	return n, err
}

// 一请求一条日志；/health 降为 debug。只记方法、路径、状态、耗时，不记请求头和请求体
func (s *Server) withAccessLog(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w}
		next.ServeHTTP(rec, r)
		level := slog.LevelInfo
		if r.URL.Path == "/health" {
			level = slog.LevelDebug
		}
		s.Log.LogAttrs(r.Context(), level, "request",
			slog.String("event", "http.request"), slog.String("trace_id", traceID(r)),
			slog.String("method", r.Method), slog.String("path", r.URL.Path),
			slog.Int("status", rec.status), slog.Int("bytes", rec.bytes),
			slog.Int64("duration_ms", time.Since(start).Milliseconds()))
	})
}

func (s *Server) withRecover(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if v := recover(); v != nil {
				s.Log.Error("panic", "trace_id", traceID(r), "panic", v)
				writeError(w, r, http.StatusInternalServerError, "internal", "服务端出错了")
			}
		}()
		next.ServeHTTP(w, r)
	})
}
