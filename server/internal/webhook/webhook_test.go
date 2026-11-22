package webhook

import (
	"context"
	"testing"
)

// Outside dev, webhooks must not reach internal addresses (SSRF); dev allows
// local receivers.
func TestCheckTargetRefusesInternalAddresses(t *testing.T) {
	ctx := context.Background()
	prod := &Dispatcher{}
	for _, u := range []string{
		"http://127.0.0.1:8080/hook",
		"http://localhost/hook",
		"https://10.1.2.3/hook",
		"https://192.168.1.10/hook",
		"http://169.254.169.254/latest/meta-data",
		"http://[::1]/hook",
		"http://0.0.0.0/hook",
	} {
		if err := prod.checkTarget(ctx, u); err == nil {
			t.Errorf("%s: internal target allowed", u)
		}
	}
	if err := prod.checkTarget(ctx, "https://203.0.113.10/hook"); err != nil {
		t.Errorf("public address refused: %v", err)
	}
	dev := &Dispatcher{AllowPrivate: true}
	if err := dev.checkTarget(ctx, "http://127.0.0.1:8080/hook"); err != nil {
		t.Errorf("dev: local receiver refused: %v", err)
	}
}
