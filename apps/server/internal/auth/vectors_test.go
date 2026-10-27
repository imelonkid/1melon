package auth

import (
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"os"
	"testing"
)

// 跨端测试向量 spec/test-vectors/sync-auth/auth.json（桌面端生成）：服务端拼的消息、验签和客户端一致。
// Argon2id 那一步服务端不做（它没有主密码），只从 authSeed 起验。
func TestSyncAuthVectors(t *testing.T) {
	raw, err := os.ReadFile("../../../../spec/test-vectors/sync-auth/auth.json")
	if err != nil {
		t.Fatal(err)
	}
	var v struct {
		Cases []struct {
			Name, AccountID, AuthSeed, PublicKey string
		}
		Login struct {
			AccountID, Challenge, Message, PublicKey, Signature string
		}
		Rotate struct {
			AccountID, AccountFile, Sha256, Message, PublicKey, Signature string
		}
		Invalid []struct {
			What, PublicKey, Message, Signature string
		}
	}
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatal(err)
	}
	b64 := func(s string) []byte {
		b, err := base64.StdEncoding.DecodeString(s)
		if err != nil {
			t.Fatal(err)
		}
		return b
	}
	if len(v.Cases) == 0 || len(v.Invalid) == 0 {
		t.Fatal("向量是空的")
	}
	for _, c := range v.Cases {
		seed, _ := hex.DecodeString(c.AuthSeed)
		pub := ed25519.NewKeyFromSeed(seed).Public().(ed25519.PublicKey)
		if !bytes.Equal(pub, b64(c.PublicKey)) {
			t.Fatalf("%s：authSeed 推出的公钥不一致", c.Name)
		}
	}

	if got := string(LoginMessage(v.Login.AccountID, v.Login.Challenge)); got != v.Login.Message {
		t.Fatalf("登录消息不一致：%s", got)
	}
	if !Verify(b64(v.Login.PublicKey), LoginMessage(v.Login.AccountID, v.Login.Challenge), b64(v.Login.Signature)) {
		t.Fatal("登录签名验不过")
	}

	sum := sha256.Sum256(b64(v.Rotate.AccountFile))
	if hex.EncodeToString(sum[:]) != v.Rotate.Sha256 {
		t.Fatal("账户文件 sha256 不一致")
	}
	if got := string(RotateMessage(v.Rotate.AccountID, v.Rotate.Sha256)); got != v.Rotate.Message {
		t.Fatalf("换钥消息不一致：%s", got)
	}
	if !Verify(b64(v.Rotate.PublicKey), RotateMessage(v.Rotate.AccountID, v.Rotate.Sha256), b64(v.Rotate.Signature)) {
		t.Fatal("换钥签名验不过")
	}

	for _, c := range v.Invalid {
		if Verify(b64(c.PublicKey), []byte(c.Message), b64(c.Signature)) {
			t.Fatalf("居然验过了：%s", c.What)
		}
	}
}
