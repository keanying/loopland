// Package ai is V2 batch 3 「AI」 (docs/api/v2-3-AI.md): the model client
// (OpenAI-compatible chat completions with streaming, tool calls, JSON mode
// and images), the assistant 圈圈 with its server-side tools, rule-based
// route suggestions, battle reports, follow-along workouts, the content
// moderation classifier and the admin usage views.
//
// The model comes live from 管理端「系统配置 → AI 大模型」; in dev without a
// configured model a deterministic mock (「开发环境模拟 AI」) answers instead.
package ai

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strings"
)

// Part is one element of a multi-part user message (text or image).
type Part struct {
	Type     string    `json:"type"`
	Text     string    `json:"text,omitempty"`
	ImageURL *ImageURL `json:"image_url,omitempty"`
}

// ImageURL is an http(s) or data: URL of an image.
type ImageURL struct {
	URL string `json:"url"`
}

// Message is a chat message. Content is a string, or []Part for a user
// message with images.
type Message struct {
	Role       string     `json:"role"`
	Content    any        `json:"content"`
	ToolCalls  []ToolCall `json:"tool_calls,omitempty"`
	ToolCallID string     `json:"tool_call_id,omitempty"`
	Name       string     `json:"name,omitempty"`
}

// Text returns the textual content of a message.
func (m Message) Text() string {
	switch c := m.Content.(type) {
	case string:
		return c
	case []Part:
		var b strings.Builder
		for _, p := range c {
			b.WriteString(p.Text)
		}
		return b.String()
	}
	return ""
}

// HasImage reports whether the message carries an image part.
func (m Message) HasImage() bool {
	ps, ok := m.Content.([]Part)
	if !ok {
		return false
	}
	for _, p := range ps {
		if p.ImageURL != nil {
			return true
		}
	}
	return false
}

// ToolCall is a function call requested by the model.
type ToolCall struct {
	ID       string       `json:"id"`
	Type     string       `json:"type"`
	Function FunctionCall `json:"function"`
}

// FunctionCall names the function and carries JSON arguments.
type FunctionCall struct {
	Name      string `json:"name"`
	Arguments string `json:"arguments"`
}

// Tool is a function the model may call.
type Tool struct {
	Type     string      `json:"type"`
	Function FunctionDef `json:"function"`
}

// FunctionDef describes a tool function with a JSON schema.
type FunctionDef struct {
	Name        string          `json:"name"`
	Description string          `json:"description"`
	Parameters  json.RawMessage `json:"parameters"`
}

// Request is one chat completion.
type Request struct {
	Model    string
	Messages []Message
	Tools    []Tool
	JSON     bool // response_format json_object
	// ToolChoice "none" forbids further tool calls (end of the tool loop).
	ToolChoice  string
	Temperature *float64
	MaxTokens   int
}

// Usage is token accounting.
type Usage struct {
	PromptTokens     int `json:"prompt_tokens"`
	CompletionTokens int `json:"completion_tokens"`
}

// Response is the model's answer.
type Response struct {
	Content      string
	ToolCalls    []ToolCall
	FinishReason string
	Usage        Usage
}

// LLM is a chat model. onDelta, when non-nil, streams the answer text as
// it is generated (SSE); the full answer is returned either way.
type LLM interface {
	Chat(ctx context.Context, req Request, onDelta func(string)) (Response, error)
}

// ---------------------------------------------------------------- OpenAI-compatible client

// OpenAI talks to an OpenAI-compatible /chat/completions endpoint.
type OpenAI struct {
	BaseURL string
	APIKey  string
	HTTP    *http.Client
}

// APIError is a non-200 answer.
type APIError struct {
	Status  int
	Message string
}

func (e *APIError) Error() string { return fmt.Sprintf("HTTP %d %s", e.Status, e.Message) }

type wireRequest struct {
	Model          string         `json:"model"`
	Messages       []Message      `json:"messages"`
	Tools          []Tool         `json:"tools,omitempty"`
	ToolChoice     string         `json:"tool_choice,omitempty"`
	Stream         bool           `json:"stream,omitempty"`
	StreamOptions  map[string]any `json:"stream_options,omitempty"`
	ResponseFormat map[string]any `json:"response_format,omitempty"`
	Temperature    *float64       `json:"temperature,omitempty"`
	MaxTokens      int            `json:"max_tokens,omitempty"`
}

type wireChoice struct {
	Message struct {
		Content   *string    `json:"content"`
		ToolCalls []ToolCall `json:"tool_calls"`
	} `json:"message"`
	Delta        wireDelta `json:"delta"`
	FinishReason *string   `json:"finish_reason"`
}

type wireDelta struct {
	Content   *string `json:"content"`
	ToolCalls []struct {
		Index    int    `json:"index"`
		ID       string `json:"id"`
		Type     string `json:"type"`
		Function struct {
			Name      string `json:"name"`
			Arguments string `json:"arguments"`
		} `json:"function"`
	} `json:"tool_calls"`
}

type wireResponse struct {
	Choices []wireChoice `json:"choices"`
	Usage   *Usage       `json:"usage"`
	Error   *struct {
		Message string `json:"message"`
	} `json:"error"`
}

// Chat implements LLM.
func (c *OpenAI) Chat(ctx context.Context, req Request, onDelta func(string)) (Response, error) {
	body := wireRequest{Model: req.Model, Messages: req.Messages, Tools: req.Tools, Temperature: req.Temperature, MaxTokens: req.MaxTokens}
	if len(req.Tools) > 0 {
		body.ToolChoice = req.ToolChoice
	}
	if req.JSON {
		body.ResponseFormat = map[string]any{"type": "json_object"}
	}
	if onDelta != nil {
		body.Stream = true
		body.StreamOptions = map[string]any{"include_usage": true}
	}
	raw, err := json.Marshal(body)
	if err != nil {
		return Response{}, err
	}
	hr, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(c.BaseURL, "/")+"/chat/completions", bytes.NewReader(raw))
	if err != nil {
		return Response{}, err
	}
	hr.Header.Set("Authorization", "Bearer "+c.APIKey)
	hr.Header.Set("Content-Type", "application/json")
	if onDelta != nil {
		hr.Header.Set("Accept", "text/event-stream")
	}
	hc := c.HTTP
	if hc == nil {
		hc = http.DefaultClient
	}
	resp, err := hc.Do(hr)
	if err != nil {
		return Response{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		var e wireResponse
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
		_ = json.Unmarshal(b, &e)
		msg := strings.TrimSpace(string(b))
		if e.Error != nil {
			msg = e.Error.Message
		}
		if len(msg) > 300 {
			msg = msg[:300]
		}
		return Response{}, &APIError{Status: resp.StatusCode, Message: msg}
	}
	ct := resp.Header.Get("Content-Type")
	if onDelta != nil && strings.HasPrefix(ct, "text/event-stream") {
		return ParseStream(resp.Body, onDelta)
	}
	// Non-streaming (or a server that ignored stream=true).
	var w wireResponse
	if err := json.NewDecoder(io.LimitReader(resp.Body, 8<<20)).Decode(&w); err != nil {
		return Response{}, fmt.Errorf("decode response: %w", err)
	}
	if len(w.Choices) == 0 {
		return Response{}, errors.New("empty response")
	}
	ch := w.Choices[0]
	out := Response{ToolCalls: ch.Message.ToolCalls}
	if ch.Message.Content != nil {
		out.Content = *ch.Message.Content
	}
	if ch.FinishReason != nil {
		out.FinishReason = *ch.FinishReason
	}
	if w.Usage != nil {
		out.Usage = *w.Usage
	}
	if onDelta != nil && out.Content != "" {
		onDelta(out.Content)
	}
	return out, nil
}

// ParseStream reads an OpenAI-style SSE stream: content deltas are passed
// to onDelta and accumulated; tool-call fragments are merged by index; the
// usage chunk (stream_options.include_usage) is kept. It stops at
// "data: [DONE]" or the end of the body.
func ParseStream(r io.Reader, onDelta func(string)) (Response, error) {
	var out Response
	var content strings.Builder
	type acc struct {
		id, typ, name string
		args          strings.Builder
	}
	calls := map[int]*acc{}
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 64<<10), 4<<20)
	var data strings.Builder
	flush := func() (bool, error) {
		payload := strings.TrimSpace(data.String())
		data.Reset()
		if payload == "" {
			return false, nil
		}
		if payload == "[DONE]" {
			return true, nil
		}
		var w wireResponse
		if err := json.Unmarshal([]byte(payload), &w); err != nil {
			return false, fmt.Errorf("bad stream chunk: %w", err)
		}
		if w.Error != nil {
			return false, &APIError{Status: http.StatusOK, Message: w.Error.Message}
		}
		if w.Usage != nil {
			out.Usage = *w.Usage
		}
		for _, ch := range w.Choices {
			if d := ch.Delta.Content; d != nil && *d != "" {
				content.WriteString(*d)
				if onDelta != nil {
					onDelta(*d)
				}
			}
			for _, tc := range ch.Delta.ToolCalls {
				a := calls[tc.Index]
				if a == nil {
					a = &acc{}
					calls[tc.Index] = a
				}
				if tc.ID != "" {
					a.id = tc.ID
				}
				if tc.Type != "" {
					a.typ = tc.Type
				}
				if tc.Function.Name != "" {
					a.name += tc.Function.Name
				}
				a.args.WriteString(tc.Function.Arguments)
			}
			if ch.FinishReason != nil && *ch.FinishReason != "" {
				out.FinishReason = *ch.FinishReason
			}
		}
		return false, nil
	}
	done := false
	for !done && sc.Scan() {
		line := strings.TrimRight(sc.Text(), "\r")
		switch {
		case line == "":
			var err error
			if done, err = flush(); err != nil {
				return out, err
			}
		case strings.HasPrefix(line, ":"): // comment / keep-alive
		case strings.HasPrefix(line, "data:"):
			if data.Len() > 0 {
				data.WriteByte('\n')
			}
			data.WriteString(strings.TrimPrefix(strings.TrimPrefix(line, "data:"), " "))
		}
	}
	if !done {
		if err := sc.Err(); err != nil {
			return out, err
		}
		if _, err := flush(); err != nil {
			return out, err
		}
	}
	out.Content = content.String()
	idx := make([]int, 0, len(calls))
	for i := range calls {
		idx = append(idx, i)
	}
	sort.Ints(idx)
	for _, i := range idx {
		a := calls[i]
		typ := a.typ
		if typ == "" {
			typ = "function"
		}
		out.ToolCalls = append(out.ToolCalls, ToolCall{ID: a.id, Type: typ, Function: FunctionCall{Name: a.name, Arguments: a.args.String()}})
	}
	return out, nil
}
