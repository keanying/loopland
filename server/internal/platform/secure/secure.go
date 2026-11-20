// Package secure handles field-level encryption of personal data and token
// hashing.
package secure

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
)

// Box encrypts phone numbers with AES-256-GCM and derives a lookup HMAC.
type Box struct {
	aead    cipher.AEAD
	hmacKey []byte
}

// NewBox builds a Box from a 32-byte key.
func NewBox(key []byte) (*Box, error) {
	if len(key) != 32 {
		return nil, errors.New("key must be 32 bytes")
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	m := hmac.New(sha256.New, key)
	m.Write([]byte("loopland/phone-lookup"))
	return &Box{aead: aead, hmacKey: m.Sum(nil)}, nil
}

// Seal encrypts plaintext (nonce || ciphertext).
func (b *Box) Seal(plain string) []byte {
	nonce := make([]byte, b.aead.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		panic(err)
	}
	return b.aead.Seal(nonce, nonce, []byte(plain), nil)
}

// Open decrypts a value produced by Seal.
func (b *Box) Open(sealed []byte) (string, error) {
	n := b.aead.NonceSize()
	if len(sealed) < n {
		return "", errors.New("ciphertext too short")
	}
	out, err := b.aead.Open(nil, sealed[:n], sealed[n:], nil)
	return string(out), err
}

// Lookup is a deterministic keyed hash for equality search.
func (b *Box) Lookup(v string) []byte {
	m := hmac.New(sha256.New, b.hmacKey)
	m.Write([]byte(v))
	return m.Sum(nil)
}

// Token returns a random URL-safe token of n bytes.
func Token(n int) string {
	buf := make([]byte, n)
	if _, err := rand.Read(buf); err != nil {
		panic(err)
	}
	return base64.RawURLEncoding.EncodeToString(buf)
}

// Hash is SHA-256, used for refresh tokens and SMS codes at rest.
func Hash(v string) []byte {
	s := sha256.Sum256([]byte(v))
	return s[:]
}

// MaskPhone renders 138****8000.
func MaskPhone(p string) string {
	if len(p) != 11 {
		return "****"
	}
	return p[:3] + "****" + p[7:]
}
