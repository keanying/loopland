// Package realtime is the WebSocket gateway (实时长连接): boss HP, attacks on
// your land, crew rally calls. Events are fanned out through Redis pub/sub so
// every API instance delivers to the clients connected to it.
package realtime

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
	"github.com/redis/go-redis/v9"
)

const channel = "loopland:realtime"

// Event is delivered to every connection subscribed to Topic, or to the
// connections of Users.
type Event struct {
	Topic   string          `json:"topic,omitempty"`
	Users   []int64         `json:"users,omitempty"`
	Payload json.RawMessage `json:"payload"`
}

// NewEvent marshals a payload.
func NewEvent(topic string, users []int64, payload any) Event {
	raw, _ := json.Marshal(payload)
	return Event{Topic: topic, Users: users, Payload: raw}
}

// Hub tracks local connections.
type Hub struct {
	Redis *redis.Client
	Log   *slog.Logger
	Auth  func(token string) (int64, error)

	mu    sync.RWMutex
	conns map[*conn]struct{}
}

type conn struct {
	user   int64
	send   chan []byte
	mu     sync.Mutex
	topics map[string]bool
}

func (c *conn) subscribed(t string) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.topics[t]
}

// Publish sends events to all instances. Errors are logged, not returned:
// realtime is best effort, clients re-sync over HTTP.
func (h *Hub) Publish(ctx context.Context, evs ...Event) {
	if h == nil {
		return
	}
	for _, e := range evs {
		raw, _ := json.Marshal(e)
		if err := h.Redis.Publish(ctx, channel, raw).Err(); err != nil {
			h.Log.Warn("realtime publish", "err", err)
		}
	}
}

// Run consumes the Redis channel until ctx ends.
func (h *Hub) Run(ctx context.Context) {
	for ctx.Err() == nil {
		sub := h.Redis.Subscribe(ctx, channel)
		ch := sub.Channel()
		for msg := range ch {
			var e Event
			if json.Unmarshal([]byte(msg.Payload), &e) == nil {
				h.deliver(e)
			}
		}
		_ = sub.Close()
		select {
		case <-ctx.Done():
		case <-time.After(time.Second):
		}
	}
}

func (h *Hub) deliver(e Event) {
	h.mu.RLock()
	defer h.mu.RUnlock()
	for c := range h.conns {
		match := e.Topic != "" && c.subscribed(e.Topic)
		for _, u := range e.Users {
			match = match || u == c.user
		}
		if !match {
			continue
		}
		select {
		case c.send <- e.Payload:
		default: // slow client: drop; it re-syncs over HTTP
		}
	}
}

// ServeHTTP upgrades GET /v1/ws?token=… .
func (h *Hub) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	tok := r.URL.Query().Get("token")
	if tok == "" {
		tok, _ = strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	}
	uid, err := h.Auth(tok)
	if err != nil || uid == 0 {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	// Long-lived connection: lift the server's read/write timeouts.
	rc := http.NewResponseController(w)
	_ = rc.SetReadDeadline(time.Time{})
	_ = rc.SetWriteDeadline(time.Time{})
	ws, err := websocket.Accept(w, r, nil)
	if err != nil {
		return
	}
	c := &conn{user: uid, send: make(chan []byte, 64), topics: map[string]bool{}}
	h.mu.Lock()
	if h.conns == nil {
		h.conns = map[*conn]struct{}{}
	}
	h.conns[c] = struct{}{}
	h.mu.Unlock()
	defer func() {
		h.mu.Lock()
		delete(h.conns, c)
		h.mu.Unlock()
	}()

	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()
	go func() { // reader
		defer cancel()
		for {
			_, data, err := ws.Read(ctx)
			if err != nil {
				return
			}
			var m struct {
				Sub   string `json:"sub"`
				Unsub string `json:"unsub"`
			}
			if json.Unmarshal(data, &m) != nil {
				continue
			}
			c.mu.Lock()
			if m.Sub != "" && len(c.topics) < 50 && strings.HasPrefix(m.Sub, "boss:") {
				c.topics[m.Sub] = true
			}
			if m.Unsub != "" {
				delete(c.topics, m.Unsub)
			}
			c.mu.Unlock()
		}
	}()
	ping := time.NewTicker(30 * time.Second)
	defer ping.Stop()
	for {
		select {
		case <-ctx.Done():
			ws.Close(websocket.StatusNormalClosure, "")
			return
		case msg := <-c.send:
			wctx, wc := context.WithTimeout(ctx, 10*time.Second)
			err := ws.Write(wctx, websocket.MessageText, msg)
			wc()
			if err != nil {
				return
			}
		case <-ping.C:
			wctx, wc := context.WithTimeout(ctx, 10*time.Second)
			err := ws.Write(wctx, websocket.MessageText, []byte(`{"type":"ping"}`))
			wc()
			if err != nil {
				return
			}
		}
	}
}
