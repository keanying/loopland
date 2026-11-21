package auth

import (
	"errors"
	"testing"
)

func TestAliyunAuthFailure(t *testing.T) {
	for _, s := range []string{"SDKError: Code: InvalidCredentials", "InvalidAccessKeyId.NotFound", "SignatureDoesNotMatch", "Forbidden.RAM"} {
		if !AliyunAuthFailure(errors.New(s)) {
			t.Errorf("%q should be an auth failure", s)
		}
	}
	if AliyunAuthFailure(errors.New("provider error: getmobile: isv.MOBILE_NUMBER_ILLEGAL")) || AliyunAuthFailure(nil) {
		t.Error("an invalid token is not an auth failure")
	}
}
