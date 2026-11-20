package billing

import (
	"crypto/ecdsa"
	"crypto/x509"
	"encoding/asn1"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// appleRootG3 is Apple Root CA - G3 (https://www.apple.com/certificateauthority/).
const appleRootG3 = `-----BEGIN CERTIFICATE-----
MIICQzCCAcmgAwIBAgIILcX8iNLFS5UwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwS
QXBwbGUgUm9vdCBDQSAtIEczMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9u
IEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcN
MTQwNDMwMTgxOTA2WhcNMzkwNDMwMTgxOTA2WjBnMRswGQYDVQQDDBJBcHBsZSBS
b290IENBIC0gRzMxJjAkBgNVBAsMHUFwcGxlIENlcnRpZmljYXRpb24gQXV0aG9y
aXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzB2MBAGByqGSM49
AgEGBSuBBAAiA2IABJjpLz1AcqTtkyJygRMc3RCV8cWjTnHcFBbZDuWmBSp3ZHtf
TjjTuxxEtX/1H7YyYl3J6YRbTzBPEVoA/VhYDKX1DyxNB0cTddqXl5dvMVztK517
IDvYuVTZXpmkOlEKMaNCMEAwHQYDVR0OBBYEFLuw3qFYM4iapIqZ3r6966/ayySr
MA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMDA2gA
MGUCMQCD6cHEFl4aXTQY2e3v9GwOAEZLuN+yRhHFD/3meoyhpmvOwgPUnPWTxnS4
at+qIxUCMG1mihDK1A3UT82NQz60imOlM27jbdoXt2QfyFMm+YhidDkLF1vLUagM
6BgD56KyKA==
-----END CERTIFICATE-----`

// Apple marker extensions: the App Store signing leaf and the WWDR G6
// intermediate.
var (
	oidAppStoreLeaf    = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 6, 11, 1}
	oidAppleWWDRInterm = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 6, 2, 1}
	errAppleSignature  = errors.New("apple jws: invalid signature or certificate chain")
)

// AppleVerifier checks App Store signed data (JWS with an x5c chain).
//
// gopay's apple.ExtractClaims only checks that the root in the header chains
// to Apple's root, and then trusts whatever key is in x5c[0]; a forged
// payload signed with any key would pass. This verifier requires the signing
// leaf to chain through the presented intermediate to the pinned root and
// to carry Apple's App Store OIDs.
type AppleVerifier struct {
	roots *x509.CertPool
	// Now is the validation time (tests override it).
	Now func() time.Time
	// Roots overrides the pinned root (tests only).
	Roots *x509.CertPool
}

// NewAppleVerifier pins Apple Root CA G3.
func NewAppleVerifier() *AppleVerifier {
	pool := x509.NewCertPool()
	block, _ := pem.Decode([]byte(appleRootG3))
	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		panic(err)
	}
	pool.AddCert(cert)
	return &AppleVerifier{roots: pool, Now: time.Now}
}

func hasExt(c *x509.Certificate, oid asn1.ObjectIdentifier) bool {
	for _, e := range c.Extensions {
		if e.Id.Equal(oid) {
			return true
		}
	}
	return false
}

// Decode verifies a JWS and unmarshals its payload into out.
func (v *AppleVerifier) Decode(signed string, out any) error {
	parts := strings.Split(signed, ".")
	if len(parts) != 3 {
		return errAppleSignature
	}
	hb, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return errAppleSignature
	}
	var hdr struct {
		Alg string   `json:"alg"`
		X5c []string `json:"x5c"`
	}
	if err := json.Unmarshal(hb, &hdr); err != nil || hdr.Alg != "ES256" || len(hdr.X5c) < 2 {
		return errAppleSignature
	}
	certs := make([]*x509.Certificate, len(hdr.X5c))
	for i, s := range hdr.X5c {
		der, err := base64.StdEncoding.DecodeString(s)
		if err != nil {
			return errAppleSignature
		}
		if certs[i], err = x509.ParseCertificate(der); err != nil {
			return errAppleSignature
		}
	}
	leaf, inter := certs[0], certs[1]
	roots := v.roots
	if v.Roots != nil {
		roots = v.Roots
	}
	inters := x509.NewCertPool()
	inters.AddCert(inter)
	if _, err := leaf.Verify(x509.VerifyOptions{Roots: roots, Intermediates: inters, CurrentTime: v.Now(),
		KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageAny}}); err != nil {
		return fmt.Errorf("%w: %v", errAppleSignature, err)
	}
	if !hasExt(leaf, oidAppStoreLeaf) || !hasExt(inter, oidAppleWWDRInterm) {
		return fmt.Errorf("%w: not an App Store certificate", errAppleSignature)
	}
	pub, ok := leaf.PublicKey.(*ecdsa.PublicKey)
	if !ok {
		return errAppleSignature
	}
	claims := jwt.MapClaims{}
	if _, err := jwt.ParseWithClaims(signed, claims, func(*jwt.Token) (any, error) { return pub, nil },
		jwt.WithValidMethods([]string{"ES256"}), jwt.WithoutClaimsValidation()); err != nil {
		return fmt.Errorf("%w: %v", errAppleSignature, err)
	}
	raw, _ := json.Marshal(claims)
	return json.Unmarshal(raw, out)
}

// AppleTransaction is the decoded JWSTransaction payload (fields we use).
type AppleTransaction struct {
	TransactionID         string `json:"transactionId"`
	OriginalTransactionID string `json:"originalTransactionId"`
	BundleID              string `json:"bundleId"`
	ProductID             string `json:"productId"`
	AppAccountToken       string `json:"appAccountToken"`
	PurchaseDate          int64  `json:"purchaseDate"`
	ExpiresDate           int64  `json:"expiresDate"`
	RevocationDate        int64  `json:"revocationDate"`
	Type                  string `json:"type"`
	Environment           string `json:"environment"`
	Price                 int64  `json:"price"` // milli-units
}

// AppleRenewal is the decoded JWSRenewalInfo payload (fields we use).
type AppleRenewal struct {
	OriginalTransactionID string `json:"originalTransactionId"`
	AutoRenewStatus       int    `json:"autoRenewStatus"`
	ProductID             string `json:"productId"`
}

// AppleNotification is a decoded App Store Server Notification V2.
type AppleNotification struct {
	NotificationType string `json:"notificationType"`
	Subtype          string `json:"subtype"`
	NotificationUUID string `json:"notificationUUID"`
	Data             struct {
		BundleID              string `json:"bundleId"`
		Environment           string `json:"environment"`
		SignedTransactionInfo string `json:"signedTransactionInfo"`
		SignedRenewalInfo     string `json:"signedRenewalInfo"`
	} `json:"data"`
}
