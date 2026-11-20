// Package httpapi exposes the service over HTTP. It is deliberately thin:
// decoding, validation and calling into the domain packages.
package httpapi

import (
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"

	"github.com/keanying/loopland/server/internal/claim"
	"github.com/keanying/loopland/server/internal/gameplay"
	"github.com/keanying/loopland/server/internal/geo"
)

// MaxTrackPoints bounds a preview request (≈ 3 h at 1 Hz).
const MaxTrackPoints = 12000

// Server wires handlers to their dependencies.
type Server struct {
	Config gameplay.Config
	Claim  claim.Options
	Log    *slog.Logger
}

// Handler returns the HTTP routes.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})
	mux.HandleFunc("GET /v1/config/gameplay", s.getGameplay)
	mux.HandleFunc("POST /v1/claims/preview", s.previewClaim)
	return mux
}

func (s *Server) getGameplay(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, s.Config)
}

type previewRequest struct {
	Sport  gameplay.Sport `json:"sport"`
	Points []geo.LatLng   `json:"points"`
}

type previewResponse struct {
	claim.Result
	DistanceKm float64 `json:"distance_km"`
	RawEnergy  int     `json:"raw_energy"`
}

// previewClaim runs a track through the loop engine. It is the same
// computation the client shows during a run; the settlement endpoint (next
// step) adds anti-cheat, the PostGIS overlap with other territory and the
// daily cap.
func (s *Server) previewClaim(w http.ResponseWriter, r *http.Request) {
	var req previewRequest
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 2<<20))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_body", err.Error())
		return
	}
	if !gameplay.GPSSports[req.Sport] {
		writeError(w, http.StatusBadRequest, "sport_cannot_claim", fmt.Sprintf("%q cannot claim land", req.Sport))
		return
	}
	if len(req.Points) > MaxTrackPoints {
		writeError(w, http.StatusRequestEntityTooLarge, "too_many_points", fmt.Sprintf("at most %d points", MaxTrackPoints))
		return
	}
	for i, p := range req.Points {
		if p.Lat < -90 || p.Lat > 90 || p.Lng < -180 || p.Lng > 180 {
			writeError(w, http.StatusBadRequest, "invalid_point", fmt.Sprintf("point %d out of range", i))
			return
		}
	}

	res := claim.Detect(req.Points, s.Claim)
	var dist float64
	for i := 1; i < len(req.Points); i++ {
		dist += geo.Haversine(req.Points[i-1], req.Points[i])
	}
	km := dist / 1000
	energy, err := s.Config.RawEnergy(req.Sport, km)
	if err != nil && !errors.Is(err, gameplay.ErrUnknownSport) {
		writeError(w, http.StatusInternalServerError, "internal", "energy calculation failed")
		return
	}
	writeJSON(w, http.StatusOK, previewResponse{Result: res, DistanceKm: km, RawEnergy: energy})
}

type apiError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func writeError(w http.ResponseWriter, status int, code, msg string) {
	writeJSON(w, status, map[string]apiError{"error": {Code: code, Message: msg}})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
