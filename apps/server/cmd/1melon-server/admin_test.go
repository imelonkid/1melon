package main

import (
	"bytes"
	"strings"
	"testing"
)

func TestAdminInviteAndAccount(t *testing.T) {
	t.Setenv("DATA_DIR", t.TempDir())
	var out bytes.Buffer
	if handled, err := admin([]string{"invite", "create", "-note", "测试", "-expires", "3d"}, &out); !handled || err != nil {
		t.Fatalf("%v %v", handled, err)
	}
	code := strings.SplitN(out.String(), "\n", 2)[0]
	if len(code) != 19 || strings.Count(code, "-") != 3 {
		t.Fatalf("邀请码格式 %q", code)
	}
	out.Reset()
	if _, err := admin([]string{"invite", "list"}, &out); err != nil || !strings.Contains(out.String(), "未用") {
		t.Fatalf("%v %q", err, out.String())
	}
	if _, err := admin([]string{"account", "disable", "11111111-2222-4333-8444-555555555555"}, &out); err == nil {
		t.Fatal("不存在的账户应报错")
	}
	if handled, _ := admin(nil, &out); handled {
		t.Fatal("没参数应启动服务")
	}
	if _, err := admin([]string{"bogus"}, &out); err == nil {
		t.Fatal("不认识的命令应报错")
	}
	if d, err := parseDuration("7d"); err != nil || d.Hours() != 168 {
		t.Fatal(d, err)
	}
}
