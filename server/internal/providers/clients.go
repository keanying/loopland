package providers

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"mime"
	"net"
	"net/http"
	"net/smtp"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// ---------------------------------------------------------------- email

// Mailer sends mail over SMTP (465: implicit TLS, otherwise STARTTLS).
type Mailer struct {
	Host, Username, Password, From, FromName string
	Port                                     int
}

// Send delivers a plain-text message.
func (m *Mailer) Send(ctx context.Context, to, subject, body string) error {
	addr := net.JoinHostPort(m.Host, strconv.Itoa(m.Port))
	d := net.Dialer{Timeout: 10 * time.Second}
	var conn net.Conn
	var err error
	if m.Port == 465 {
		conn, err = tls.DialWithDialer(&d, "tcp", addr, &tls.Config{ServerName: m.Host})
	} else {
		conn, err = d.DialContext(ctx, "tcp", addr)
	}
	if err != nil {
		return err
	}
	if dl, ok := ctx.Deadline(); ok {
		_ = conn.SetDeadline(dl)
	}
	c, err := smtp.NewClient(conn, m.Host)
	if err != nil {
		conn.Close()
		return err
	}
	defer c.Close()
	if m.Port != 465 {
		if ok, _ := c.Extension("STARTTLS"); ok {
			if err := c.StartTLS(&tls.Config{ServerName: m.Host}); err != nil {
				return err
			}
		}
	}
	if err := c.Auth(smtp.PlainAuth("", m.Username, m.Password, m.Host)); err != nil {
		return fmt.Errorf("SMTP 认证失败：%w", err)
	}
	if err := c.Mail(m.From); err != nil {
		return err
	}
	if err := c.Rcpt(to); err != nil {
		return err
	}
	w, err := c.Data()
	if err != nil {
		return err
	}
	from := m.From
	if m.FromName != "" {
		from = mime.QEncoding.Encode("utf-8", m.FromName) + " <" + m.From + ">"
	}
	msg := "From: " + from + "\r\nTo: " + to + "\r\nSubject: " + mime.QEncoding.Encode("utf-8", subject) +
		"\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: 8bit\r\nDate: " +
		time.Now().Format(time.RFC1123Z) + "\r\n\r\n" + strings.ReplaceAll(body, "\n", "\r\n")
	if _, err := w.Write([]byte(msg)); err != nil {
		return err
	}
	if err := w.Close(); err != nil {
		return err
	}
	return c.Quit()
}

// ---------------------------------------------------------------- AI

// AIConfig is the model gateway configuration (技术选型 · AI 能力).
type AIConfig struct {
	Vendor          string `json:"vendor"`
	BaseURL         string `json:"base_url"`
	APIKey          string `json:"-"`
	Model           string `json:"model"`
	SmallModel      string `json:"small_model"`
	DisplayName     string `json:"display_name"`
	RegistrationNo  string `json:"registration_no"`
	WeeklyFreeQuota int    `json:"weekly_free_quota"`
	TimeoutS        int    `json:"timeout_s"`
}

// Endpoint returns the effective base URL.
func (a AIConfig) Endpoint() string {
	if a.BaseURL != "" {
		return strings.TrimRight(a.BaseURL, "/")
	}
	return AIVendors[a.Vendor]
}

// Check sends a one-token chat completion: proves URL, key and model.
func (a AIConfig) Check(ctx context.Context, hc *http.Client) error {
	if a.Endpoint() == "" {
		return fmt.Errorf("没有接口地址")
	}
	body, _ := json.Marshal(map[string]any{"model": a.Model, "max_tokens": 1,
		"messages": []map[string]string{{"role": "user", "content": "ping"}}})
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, a.Endpoint()+"/chat/completions", strings.NewReader(string(body)))
	req.Header.Set("Authorization", "Bearer "+a.APIKey)
	req.Header.Set("Content-Type", "application/json")
	resp, err := hc.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		var e struct {
			Error struct {
				Message string `json:"message"`
			} `json:"error"`
		}
		_ = json.NewDecoder(resp.Body).Decode(&e)
		return fmt.Errorf("HTTP %d %s", resp.StatusCode, e.Error.Message)
	}
	return nil
}

// ---------------------------------------------------------------- AMap

// AMapCheck validates a Web service key with the IP location API.
func AMapCheck(ctx context.Context, hc *http.Client, key string) error {
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, "https://restapi.amap.com/v3/ip?key="+url.QueryEscape(key), nil)
	resp, err := hc.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	var r struct {
		Status string `json:"status"`
		Info   string `json:"info"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&r); err != nil {
		return err
	}
	if r.Status != "1" {
		return fmt.Errorf("高德返回 %s", r.Info)
	}
	return nil
}
