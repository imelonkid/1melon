package httpapi

import (
	"net"
	"net/http"
	"strings"
	"sync"
	"time"
)

// limiter：进程内的令牌桶（单实例，重启清零；spec/sync-api.md、README 技术选型例外）。
// 每个键每分钟 perMinute 个令牌，最多攒 burst 个。
type limiter struct {
	mu        sync.Mutex
	perMinute float64
	burst     float64
	buckets   map[string]*bucket
	lastSweep time.Time
}

type bucket struct {
	tokens float64
	at     time.Time
}

func newLimiter(perMinute, burst int) *limiter {
	return &limiter{perMinute: float64(perMinute), burst: float64(burst), buckets: map[string]*bucket{}}
}

// allow：允许就返回 0；否则返回要等多少秒
func (l *limiter) allow(key string, now time.Time) int {
	l.mu.Lock()
	defer l.mu.Unlock()
	if now.Sub(l.lastSweep) > 10*time.Minute {
		for k, b := range l.buckets {
			if now.Sub(b.at) > 10*time.Minute {
				delete(l.buckets, k)
			}
		}
		l.lastSweep = now
	}
	b, ok := l.buckets[key]
	if !ok {
		b = &bucket{tokens: l.burst, at: now}
		l.buckets[key] = b
	}
	b.tokens = min(l.burst, b.tokens+now.Sub(b.at).Minutes()*l.perMinute)
	b.at = now
	if b.tokens >= 1 {
		b.tokens--
		return 0
	}
	return int((1-b.tokens)/l.perMinute*60) + 1
}

// clientIP：只有配置了可信的反向代理头（TRUSTED_PROXY_HEADER，如 X-Real-IP）才用它，否则用连接地址，防止伪造
func clientIP(r *http.Request, header string) string {
	if header != "" {
		if v := strings.TrimSpace(strings.Split(r.Header.Get(header), ",")[0]); v != "" {
			return v
		}
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}
