package ai

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/keanying/loopland/server/internal/moderation"
)

var targetNames = map[string]string{moderation.Post: "动态", moderation.Comment: "评论", moderation.Nickname: "昵称", moderation.Avatar: "头像",
	moderation.CrewName: "跑团名称", moderation.CrewAvatar: "跑团头像", moderation.Bio: "个人简介", moderation.Meetup: "组局"}

// Classifier adapts the service to moderation.Classifier: the small model
// scores the text, the vision model (when configured) also looks at the
// images.
type Classifier struct{ Svc *Service }

// Classify implements moderation.Classifier.
func (c Classifier) Classify(ctx context.Context, in moderation.Content) (*moderation.Verdict, error) {
	s := c.Svc
	b, err := s.Backend()
	if err != nil {
		return nil, moderation.ErrNoAI
	}
	images := in.Images
	if !b.Vision() {
		images = nil
	}
	if strings.TrimSpace(in.Text) == "" && len(images) == 0 {
		return nil, moderation.ErrNoAI
	}
	if len(images) > 9 {
		images = images[:9]
	}
	what := targetNames[in.Target]
	if what == "" {
		what = in.Target
	}
	text := fmt.Sprintf("类型：%s\n正文：%s", what, in.Text)
	req := Request{Model: b.SmallModel, MaxTokens: 300, Messages: []Message{{Role: "system", Content: fmt.Sprintf(promptModeration, what)}}}
	if len(images) == 0 {
		req.JSON = true
		req.Messages = append(req.Messages, Message{Role: "user", Content: text})
	} else {
		req.Model = b.VisionModel
		parts := []Part{{Type: "text", Text: text + fmt.Sprintf("\n图片：%d 张（按顺序）", len(images))}}
		for _, u := range images {
			parts = append(parts, Part{Type: "image_url", ImageURL: &ImageURL{URL: s.modelImageURL(ctx, u)}})
		}
		req.Messages = append(req.Messages, Message{Role: "user", Content: parts})
	}
	resp, err := s.Call(ctx, b, FeatureModeration, in.UserID, req, nil)
	if err != nil {
		return nil, err
	}
	var out struct {
		RiskScore  float64  `json:"risk_score"`
		Labels     []string `json:"labels"`
		Reason     string   `json:"reason"`
		Confidence float64  `json:"confidence"`
		Suggestion string   `json:"suggestion"`
		BadImages  []int    `json:"bad_images"`
	}
	if err := json.Unmarshal([]byte(extractJSON(resp.Content)), &out); err != nil {
		return nil, fmt.Errorf("moderation answer is not JSON: %w", err)
	}
	v := &moderation.Verdict{RiskScore: int(out.RiskScore + 0.5), Labels: out.Labels, Reason: out.Reason, Confidence: out.Confidence,
		Suggestion: out.Suggestion, ModelName: b.ModelName, FlaggedImages: []string{}}
	for _, i := range out.BadImages {
		if i >= 1 && i <= len(images) {
			v.FlaggedImages = append(v.FlaggedImages, images[i-1])
		}
	}
	v.Normalize()
	return v, nil
}

// modelImageURL turns a stored image url into one the model can open
// (local dev uploads become data URLs).
func (s *Service) modelImageURL(ctx context.Context, url string) string {
	var storage, key, ct string
	if err := s.Pool.QueryRow(ctx, `SELECT storage_type, object_key, content_type FROM src.src_cnt_loop_media WHERE url=$1 ORDER BY id DESC LIMIT 1`, url).
		Scan(&storage, &key, &ct); err != nil {
		return url
	}
	return s.imageSource(url, storage, key, ct)
}
