package config

import "testing"

func TestAddr(t *testing.T) {
	cases := []struct {
		bind, port, want string
	}{
		{"", "", ":8790"},
		{"", "9000", ":9000"},
		{"127.0.0.1", "", "127.0.0.1:8790"},
		{"::1", "8790", "[::1]:8790"},
	}
	for _, c := range cases {
		t.Setenv("BIND_ADDR", c.bind)
		t.Setenv("PORT", c.port)
		cfg, err := Load()
		if err != nil {
			t.Fatalf("BIND_ADDR=%q PORT=%q：%v", c.bind, c.port, err)
		}
		if cfg.Addr != c.want {
			t.Errorf("BIND_ADDR=%q PORT=%q：Addr = %q，应为 %q", c.bind, c.port, cfg.Addr, c.want)
		}
	}
}

func TestBadBindAddr(t *testing.T) {
	for _, bind := range []string{"localhost", "0.0.0.0:8790", "1.2.3"} {
		t.Setenv("BIND_ADDR", bind)
		if _, err := Load(); err == nil {
			t.Errorf("BIND_ADDR=%q 应报错", bind)
		}
	}
}
