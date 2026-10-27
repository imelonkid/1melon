package auth

import (
	"encoding/base64"
	"testing"
	"time"
)

func TestChallenge(t *testing.T) {
	key := []byte("0123456789abcdef0123456789abcdef")
	acct := "11111111-2222-4333-8444-555555555555"
	now := time.Now()
	c, exp := NewChallenge(key, acct, now)
	if _, e, err := VerifyChallenge(key, acct, c, now); err != nil || e != exp {
		t.Fatalf("应通过 %v", err)
	}
	if _, _, err := VerifyChallenge(key, acct, c, now.Add(ChallengeTTL+time.Second)); err == nil {
		t.Fatal("过期应拒绝")
	}
	if _, _, err := VerifyChallenge(key, "22222222-2222-4333-8444-555555555555", c, now); err == nil {
		t.Fatal("别的账户的挑战应拒绝")
	}
	if _, _, err := VerifyChallenge([]byte("another-server-key-another-key!!"), acct, c, now); err == nil {
		t.Fatal("别的服务端发的应拒绝")
	}
	raw, _ := base64.StdEncoding.DecodeString(c)
	raw[20] ^= 1 // 改过期时间
	if _, _, err := VerifyChallenge(key, acct, base64.StdEncoding.EncodeToString(raw), now); err == nil {
		t.Fatal("改过的应拒绝")
	}
}

func TestCheckFile(t *testing.T) {
	acct := "11111111-2222-4333-8444-555555555555"
	vault := "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
	ok := map[string]string{
		"account.1melon":              `{"format":"1melon-account","version":2,"accountId":"` + acct + `","secretKey":"required","kdf":{}}`,
		"vaults/" + vault + ".1melon": `{"format":"1melon-vault","accountId":"` + acct + `","vaultId":"` + vault + `"}`,
	}
	for name, body := range ok {
		if _, err := CheckFile(name, acct, []byte(body)); err != nil {
			t.Fatalf("%s 应通过", name)
		}
	}
	bad := map[string]string{
		"account.1melon":                                     `{"format":"1melon-account","version":1,"accountId":"` + acct + `","secretKey":"none","kdf":{}}`,
		"vaults/" + vault + ".1melon":                        `{"format":"1melon-vault","accountId":"22222222-2222-4333-8444-555555555555","vaultId":"` + vault + `"}`,
		"vaults/" + vault + ".json":                          `{}`,
		"vaults/AAAAAAAA-bbbb-4ccc-8ddd-eeeeeeeeeeee.1melon": `{}`,
		"../account.1melon":                                  `{}`,
	}
	for name, body := range bad {
		if _, err := CheckFile(name, acct, []byte(body)); err == nil {
			t.Fatalf("%s 应拒绝", name)
		}
	}
}
