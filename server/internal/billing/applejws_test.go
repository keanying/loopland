package billing

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"math/big"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

type certKey struct {
	cert *x509.Certificate
	der  []byte
	key  *ecdsa.PrivateKey
}

func mkCert(t *testing.T, name string, parent *certKey, ca bool, ext []pkix.Extension) *certKey {
	t.Helper()
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(time.Now().UnixNano()), Subject: pkix.Name{CommonName: name},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour),
		IsCA: ca, BasicConstraintsValid: true, ExtraExtensions: ext,
		KeyUsage: x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign,
	}
	signer, parentCert := key, tmpl
	if parent != nil {
		signer, parentCert = parent.key, parent.cert
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, parentCert, &key.PublicKey, signer)
	if err != nil {
		t.Fatal(err)
	}
	c, _ := x509.ParseCertificate(der)
	return &certKey{cert: c, der: der, key: key}
}

func sign(t *testing.T, signer *ecdsa.PrivateKey, chain ...*certKey) string {
	x5c := make([]string, len(chain))
	for i, c := range chain {
		x5c[i] = base64.StdEncoding.EncodeToString(c.der)
	}
	tok := jwt.NewWithClaims(jwt.SigningMethodES256, jwt.MapClaims{
		"transactionId": "1000", "originalTransactionId": "1000", "bundleId": "com.loopland.app", "productId": "p",
		"appAccountToken": "4f1c6a6e-2b0b-4a1b-9a65-0d3a6c1c0c11", "expiresDate": 1893456000000,
	})
	tok.Header["x5c"] = x5c
	s, err := tok.SignedString(signer)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func TestAppleVerifier(t *testing.T) {
	leafExt := []pkix.Extension{{Id: oidAppStoreLeaf, Value: []byte{5, 0}}}
	interExt := []pkix.Extension{{Id: oidAppleWWDRInterm, Value: []byte{5, 0}}}
	root := mkCert(t, "Fake Apple Root", nil, true, nil)
	inter := mkCert(t, "Fake WWDR", root, true, interExt)
	leaf := mkCert(t, "Fake App Store", inter, false, leafExt)

	v := NewAppleVerifier()
	v.Roots = x509.NewCertPool()
	v.Roots.AddCert(root.cert)

	var tx AppleTransaction
	if err := v.Decode(sign(t, leaf.key, leaf, inter, root), &tx); err != nil {
		t.Fatalf("valid chain rejected: %v", err)
	}
	if tx.TransactionID != "1000" || tx.BundleID != "com.loopland.app" || tx.ExpiresDate != 1893456000000 {
		t.Fatalf("decoded %+v", tx)
	}

	// The attack gopay's ExtractClaims allows: a self-made leaf presented
	// together with the genuine intermediate and root.
	forged := mkCert(t, "Attacker", nil, false, leafExt)
	if err := v.Decode(sign(t, forged.key, forged, inter, root), &tx); err == nil {
		t.Fatal("forged leaf accepted")
	}
	// Signed with a different key than the leaf's.
	other, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err := v.Decode(sign(t, other, leaf, inter, root), &tx); err == nil {
		t.Fatal("wrong signing key accepted")
	}
	// A chain without Apple's marker OIDs.
	plainLeaf := mkCert(t, "Plain", inter, false, nil)
	if err := v.Decode(sign(t, plainLeaf.key, plainLeaf, inter, root), &tx); err == nil {
		t.Fatal("leaf without App Store OID accepted")
	}
	// The real pinned root rejects our fake chain.
	if err := NewAppleVerifier().Decode(sign(t, leaf.key, leaf, inter, root), &tx); err == nil {
		t.Fatal("fake root accepted by the pinned verifier")
	}
}
