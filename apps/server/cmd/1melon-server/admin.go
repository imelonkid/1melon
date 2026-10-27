package main

import (
	"context"
	"crypto/rand"
	"encoding/base32"
	"errors"
	"flag"
	"fmt"
	"io"
	"strconv"
	"strings"
	"time"

	"github.com/imelonkid/1melon/apps/server/internal/auth"
	"github.com/imelonkid/1melon/apps/server/internal/config"
	"github.com/imelonkid/1melon/apps/server/internal/store"
)

const usage = `用法（在服务器上通过部署入口执行，直接读写数据目录里的库；spec/sync-api.md §8）：
  1melon-server                                   启动服务
  1melon-server version                           打印版本
  1melon-server invite create [-note 给谁] [-expires 7d]   生成一次性邀请码（只显示这一次）
  1melon-server invite list
  1melon-server account list                      账户、注册时间、用量、设备数（看不到内容）
  1melon-server account disable <accountId>       停用：会话立即失效
  1melon-server account enable <accountId>
`

// admin：管理命令。返回 handled=false 表示不是管理命令（该启动服务）
func admin(args []string, out io.Writer) (handled bool, err error) {
	if len(args) == 0 {
		return false, nil
	}
	if args[0] == "help" || args[0] == "-h" || args[0] == "--help" {
		fmt.Fprint(out, usage)
		return true, nil
	}
	if args[0] != "invite" && args[0] != "account" {
		return true, fmt.Errorf("不认识的命令 %q\n%s", args[0], usage)
	}
	if len(args) < 2 {
		return true, errors.New(usage)
	}
	cfg, err := config.Load()
	if err != nil {
		return true, err
	}
	db, err := store.Open(cfg.DataDir)
	if err != nil {
		return true, err
	}
	defer db.Close()
	ctx := context.Background()

	switch args[0] + " " + args[1] {
	case "invite create":
		fs := flag.NewFlagSet("invite create", flag.ContinueOnError)
		note := fs.String("note", "", "备注：给谁的")
		expires := fs.String("expires", "7d", "多久后过期，如 7d、24h")
		if err := fs.Parse(args[2:]); err != nil {
			return true, err
		}
		ttl, err := parseDuration(*expires)
		if err != nil {
			return true, err
		}
		code := newInviteCode()
		if err := db.CreateInvite(ctx, code, *note, ttl); err != nil {
			return true, err
		}
		fmt.Fprintf(out, "%s\n（%s 后过期；库里只存它的哈希，现在不抄下来就找不回了）\n", code, *expires)
	case "invite list":
		invites, err := db.ListInvites(ctx)
		if err != nil {
			return true, err
		}
		for _, i := range invites {
			state := "未用"
			switch {
			case i.UsedAt > 0:
				state = "已用 → " + i.UsedBy
			case i.ExpiresAt < time.Now().UnixMilli():
				state = "已过期"
			}
			fmt.Fprintf(out, "%s  %-10s  %s\n", fmtTime(i.CreatedAt), state, i.Note)
		}
	case "account list":
		accounts, err := db.ListAccounts(ctx)
		if err != nil {
			return true, err
		}
		for _, a := range accounts {
			state := ""
			if a.Disabled {
				state = "（已停用）"
			}
			fmt.Fprintf(out, "%s  %s  %d 个文件  %.1f KB  %d 台设备%s\n", a.ID, fmtTime(a.CreatedAt), a.Files, float64(a.Bytes)/1024, a.Devices, state)
		}
	case "account disable", "account enable":
		if len(args) != 3 || !auth.IsUUID(args[2]) {
			return true, errors.New("要给一个 accountId（小写 UUID）")
		}
		disable := args[1] == "disable"
		if err := db.SetDisabled(ctx, args[2], disable); err != nil {
			return true, err
		}
		fmt.Fprintf(out, "已%s %s\n", map[bool]string{true: "停用", false: "启用"}[disable], args[2])
	default:
		return true, fmt.Errorf("不认识的命令 %q\n%s", strings.Join(args[:2], " "), usage)
	}
	return true, nil
}

// newInviteCode：16 个 Base32 字符（80 位随机），每 4 个一组
func newInviteCode() string {
	b := make([]byte, 10)
	_, _ = rand.Read(b)
	s := base32.StdEncoding.EncodeToString(b)
	return s[0:4] + "-" + s[4:8] + "-" + s[8:12] + "-" + s[12:16]
}

func parseDuration(s string) (time.Duration, error) {
	if d, ok := strings.CutSuffix(s, "d"); ok {
		n, err := strconv.Atoi(d)
		if err != nil || n < 1 || n > 365 {
			return 0, fmt.Errorf("过期时间不对：%q", s)
		}
		return time.Duration(n) * 24 * time.Hour, nil
	}
	d, err := time.ParseDuration(s)
	if err != nil || d <= 0 {
		return 0, fmt.Errorf("过期时间不对：%q", s)
	}
	return d, nil
}

func fmtTime(ms int64) string { return time.UnixMilli(ms).Format("2006-01-02 15:04") }
