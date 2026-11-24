// Package nickname generates default nicknames: 「圈圈」 + a sports
// description, e.g. 圈圈晨跑侠, 圈圈夜骑达人, 圈圈环湖跑小将.
package nickname

import (
	"crypto/rand"
	"math/big"
)

// Prefix starts every default nickname.
const Prefix = "圈圈"

// actions describe the sport (all sports the app records, not only running).
var actions = []string{
	"晨跑", "夜跑", "慢跑", "环湖跑", "越野跑", "追风跑", "爬坡跑", "城市跑",
	"骑行", "夜骑", "飞驰骑", "健走", "暴走", "徒步", "登山", "游泳",
	"跳绳", "羽毛球", "匹克球", "篮球", "飞盘", "攀岩",
}

// roles are friendly role words after the action.
var roles = []string{"侠", "客", "达人", "小将", "星人", "玩家", "选手", "队长", "高手", "新秀"}

// Count is the number of distinct default nicknames.
var Count = len(actions) * len(roles)

func pick(i int) string {
	i %= Count
	if i < 0 {
		i += Count
	}
	return Prefix + actions[i/len(roles)] + roles[i%len(roles)]
}

// Random returns a random default nickname (at registration).
func Random() string {
	n, err := rand.Int(rand.Reader, big.NewInt(int64(Count)))
	if err != nil {
		return pick(0)
	}
	return pick(int(n.Int64()))
}

// ForID returns a stable default nickname for a user (when a nickname is
// reset by moderation): the same user always gets the same one.
func ForID(id int64) string {
	// Spread consecutive ids over the list (Knuth multiplicative hash).
	return pick(int((uint64(id) * 2654435761) % uint64(Count)))
}
