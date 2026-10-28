package auth

import (
	"encoding/json"
	"errors"
	"regexp"
)

var (
	fileName = regexp.MustCompile(`^(vaults|attachments)/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.1melon$`)
	uuidRe   = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
)

var ErrBadFile = errors.New("bad file")

func IsUUID(s string) bool { return uuidRe.MatchString(s) }

// FileKind：三种文件（spec §5）
type FileKind int

const (
	AccountFile FileKind = iota + 1
	VaultFile
	AttachmentFile
)

// ParseName：合法的文件名返回种类和 id（保险库是 vaultId，附件是 attachmentId，账户文件是 ""）；别的返回 false
func ParseName(name string) (FileKind, string, bool) {
	if name == "account.1melon" {
		return AccountFile, "", true
	}
	m := fileName.FindStringSubmatch(name)
	if m == nil {
		return 0, "", false
	}
	if m[1] == "vaults" {
		return VaultFile, m[2], true
	}
	return AttachmentFile, m[2], true
}

// AccountHeader：账户文件的公开字段（服务端只读这些，不解密）
type AccountHeader struct {
	Format    string          `json:"format"`
	Version   int             `json:"version"`
	AccountID string          `json:"accountId"`
	SecretKey string          `json:"secretKey"`
	KDF       json.RawMessage `json:"kdf"`
}

// CheckFile：最少的检查（spec §5.3）：是 JSON、format 对、属于这个账户、保险库 / 附件的 id 和文件名一致；账户文件必须是 v2（带 Secret Key）
func CheckFile(name, accountID string, content []byte) (*AccountHeader, error) {
	kind, id, ok := ParseName(name)
	if !ok {
		return nil, ErrBadFile
	}
	if kind == AccountFile {
		var h AccountHeader
		if json.Unmarshal(content, &h) != nil || h.Format != "1melon-account" || h.Version != 2 ||
			h.AccountID != accountID || h.SecretKey != "required" || len(h.KDF) == 0 {
			return nil, ErrBadFile
		}
		return &h, nil
	}
	var v struct {
		Format       string `json:"format"`
		AccountID    string `json:"accountId"`
		VaultID      string `json:"vaultId"`
		AttachmentID string `json:"attachmentId"`
	}
	if json.Unmarshal(content, &v) != nil || v.AccountID != accountID {
		return nil, ErrBadFile
	}
	if kind == VaultFile && (v.Format != "1melon-vault" || v.VaultID != id) ||
		kind == AttachmentFile && (v.Format != "1melon-attachment" || v.AttachmentID != id) {
		return nil, ErrBadFile
	}
	return nil, nil
}
