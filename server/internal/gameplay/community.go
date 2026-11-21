package gameplay

import "fmt"

// CommunitySettings tune 社区 (docs/api/v2-2-社区.md «玩法配置新增字段»).
type CommunitySettings struct {
	// DailyPostLimit is how many posts one user may publish per day.
	DailyPostLimit int `json:"daily_post_limit"`
	// HideEndpointsM is the radius around the start and end of a track
	// that is cut off when the author hides endpoints (settings.hide_endpoints).
	HideEndpointsM float64 `json:"hide_endpoints_m"`
}

func defaultCommunity(c *Config) {
	c.Community = CommunitySettings{DailyPostLimit: 20, HideEndpointsM: 200}
}

// normalizeCommunity fills the section for configurations stored before it existed.
func (c *Config) normalizeCommunity() {
	d := CommunitySettings{}
	if c.Community == d {
		defaultCommunity(c)
	}
}

func (c Config) validateCommunity() error {
	if c.Community.DailyPostLimit < 1 {
		return fmt.Errorf("community: 每日发帖上限至少为 1")
	}
	if c.Community.HideEndpointsM < 0 || c.Community.HideEndpointsM > 2000 {
		return fmt.Errorf("community: 隐藏起终点半径应在 0–2000 米之间")
	}
	return nil
}
