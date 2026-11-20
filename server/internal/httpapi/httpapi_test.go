package httpapi

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/keanying/loopland/server/internal/gameplay"
	"github.com/keanying/loopland/server/internal/geo"
)

func newServer() http.Handler {
	return (&Server{Config: gameplay.Default()}).Handler()
}

func post(t *testing.T, h http.Handler, path string, body any) *httptest.ResponseRecorder {
	t.Helper()
	b, _ := json.Marshal(body)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, path, bytes.NewReader(b)))
	return rec
}

func TestHealthz(t *testing.T) {
	rec := httptest.NewRecorder()
	newServer().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if rec.Code != http.StatusOK {
		t.Fatal(rec.Code)
	}
}

func TestGameplayConfig(t *testing.T) {
	rec := httptest.NewRecorder()
	newServer().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/v1/config/gameplay", nil))
	var c gameplay.Config
	if err := json.Unmarshal(rec.Body.Bytes(), &c); err != nil {
		t.Fatal(err)
	}
	if c.DailyEnergyCap != 600 || len(c.Buildings) != 8 {
		t.Fatalf("got %+v", c)
	}
}

func TestPreviewClaim(t *testing.T) {
	p := geo.NewProjection(geo.LatLng{Lat: 31.2304, Lng: 121.4737})
	var pts []geo.LatLng
	for _, xy := range [][2]float64{{0, 0}, {300, 0}, {300, 300}, {150, 300}, {150, -100}} {
		pts = append(pts, p.Inverse(geo.Point{X: xy[0], Y: xy[1]}))
	}
	rec := post(t, newServer(), "/v1/claims/preview", map[string]any{"sport": "run", "points": pts})
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d: %s", rec.Code, rec.Body)
	}
	var resp previewResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if len(resp.Loops) != 1 || resp.TotalAreaM2 < 44900 || resp.TotalAreaM2 > 45100 {
		t.Fatalf("loops=%d area=%.0f", len(resp.Loops), resp.TotalAreaM2)
	}
	// 300+300+150+400 = 1150 m → 11 energy
	if resp.RawEnergy != 11 {
		t.Fatalf("energy = %d (distance %.3f km)", resp.RawEnergy, resp.DistanceKm)
	}
}

func TestPreviewRejectsIndoorSport(t *testing.T) {
	rec := post(t, newServer(), "/v1/claims/preview", map[string]any{"sport": "yoga", "points": []any{}})
	if rec.Code != http.StatusBadRequest {
		t.Fatal(rec.Code)
	}
}

func TestPreviewRejectsBadPoint(t *testing.T) {
	rec := post(t, newServer(), "/v1/claims/preview", map[string]any{
		"sport": "run", "points": []map[string]float64{{"lat": 91, "lng": 0}},
	})
	if rec.Code != http.StatusBadRequest {
		t.Fatal(rec.Code)
	}
}
