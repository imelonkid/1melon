// Package auth：登录挑战和签名校验（spec/sync-api.md §3）。服务端只有各账户的登录公钥，看不到主密码和 Secret Key。
package auth

import (
	"crypto/ed25519"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"time"
)

// ChallengeTTL：挑战 2 分钟内有效
const ChallengeTTL = 2 * time.Minute

var ErrBadChallenge = errors.New("bad challenge")

// Challenge：nonce(16) ‖ expiresAt(8, 大端毫秒) ‖ HMAC-SHA256(serverKey, "challenge" ‖ accountId ‖ nonce ‖ expiresAt) 的前 16 字节。
// 自带过期时间和服务端签名，服务端不用记录发出过哪些挑战；「只能用一次」在换会话时登记。
func NewChallenge(serverKey []byte, accountID string, now time.Time) (string, int64) {
	nonce := make([]byte, 16)
	_, _ = rand.Read(nonce)
	exp := now.Add(ChallengeTTL).UnixMilli()
	return encode(serverKey, accountID, nonce, exp), exp
}

func encode(serverKey []byte, accountID string, nonce []byte, exp int64) string {
	buf := make([]byte, 0, 40)
	buf = append(buf, nonce...)
	buf = binary.BigEndian.AppendUint64(buf, uint64(exp))
	buf = append(buf, mac(serverKey, accountID, buf)...)
	return base64.StdEncoding.EncodeToString(buf)
}

func mac(serverKey []byte, accountID string, body []byte) []byte {
	m := hmac.New(sha256.New, serverKey)
	m.Write([]byte("challenge:" + accountID + ":"))
	m.Write(body)
	return m.Sum(nil)[:16]
}

// VerifyChallenge：确认挑战是这台服务端给这个账户发的、还没过期。返回 nonce 和过期时间（登记「已用」用）
func VerifyChallenge(serverKey []byte, accountID, challenge string, now time.Time) (nonce []byte, exp int64, err error) {
	raw, err := base64.StdEncoding.DecodeString(challenge)
	if err != nil || len(raw) != 40 {
		return nil, 0, ErrBadChallenge
	}
	if !hmac.Equal(raw[24:], mac(serverKey, accountID, raw[:24])) {
		return nil, 0, ErrBadChallenge
	}
	exp = int64(binary.BigEndian.Uint64(raw[16:24]))
	if now.UnixMilli() > exp {
		return nil, 0, ErrBadChallenge
	}
	return raw[:16], exp, nil
}

// LoginMessage：签名的消息（spec §3.2）
func LoginMessage(accountID, challenge string) []byte {
	return []byte("1melon:v1:auth:" + accountID + ":" + challenge)
}

// RotateMessage：上传账户文件时，新登录私钥对它签名（spec §5.3）
func RotateMessage(accountID, sha256Hex string) []byte {
	return []byte("1melon:v1:rotate:" + accountID + ":" + sha256Hex)
}

func Verify(publicKey []byte, message []byte, signature []byte) bool {
	return len(publicKey) == ed25519.PublicKeySize && len(signature) == ed25519.SignatureSize &&
		ed25519.Verify(ed25519.PublicKey(publicKey), message, signature)
}

// FakeKDF：账户不存在时也返回一套看起来真实的 KDF 参数（salt 由 accountId 确定），不暴露账户是否存在
func FakeKDF(serverKey []byte, accountID string) map[string]any {
	m := hmac.New(sha256.New, serverKey)
	m.Write([]byte("fake-kdf-salt:" + accountID))
	return map[string]any{
		"alg": "argon2id13", "memKiB": 262144, "iterations": 3, "parallelism": 1,
		"salt": base64.StdEncoding.EncodeToString(m.Sum(nil)[:16]),
	}
}
