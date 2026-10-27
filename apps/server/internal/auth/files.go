package auth

import (
	"encoding/json"
	"errors"
	"regexp"
)

var (
	vaultName = regexp.MustCompile(`^vaults/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.1melon$`)
	uuidRe    = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
)

var ErrBadFile = errors.New("bad file")

func IsUUID(s string) bool { return uuidRe.MatchString(s) }

// VaultIDFromName：合法的保险库文件名返回 vaultId；账户文件返回 ""、true；别的返回 false
func VaultIDFromName(name string) (string, bool) {
	if name == "account.1melon" {
		return "", true
	}
	m := vaultName.FindStringSubmatch(name)
	if m == nil {
		return "", false
	}
	return m[1], true
}

// AccountHeader：账户文件的公开字段（服务端只读这些，不解密）
type AccountHeader struct {
	Format    string          `json:"format"`
	Version   int             `json:"version"`
	AccountID string          `json:"accountId"`
	SecretKey string          `json:"secretKey"`
	KDF       json.RawMessage `json:"kdf"`
}

// CheckFile：最少的检查（spec §5.3）：是 JSON、format 对、属于这个账户、保险库 id 和文件名一致；账户文件必须是 v2（带 Secret Key）
func CheckFile(name, accountID string, content []byte) (*AccountHeader, error) {
	vaultID, ok := VaultIDFromName(name)
	if !ok {
		return nil, ErrBadFile
	}
	if vaultID == "" {
		var h AccountHeader
		if json.Unmarshal(content, &h) != nil || h.Format != "1melon-account" || h.Version != 2 ||
			h.AccountID != accountID || h.SecretKey != "required" || len(h.KDF) == 0 {
			return nil, ErrBadFile
		}
		return &h, nil
	}
	var v struct {
		Format    string `json:"format"`
		AccountID string `json:"accountId"`
		VaultID   string `json:"vaultId"`
	}
	if json.Unmarshal(content, &v) != nil || v.Format != "1melon-vault" || v.AccountID != accountID || v.VaultID != vaultID {
		return nil, ErrBadFile
	}
	return nil, nil
}
