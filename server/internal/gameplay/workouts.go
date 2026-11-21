package gameplay

import "fmt"

// WorkoutStep is one move of an AI follow-along workout (AI 跟练,
// docs/api/v2-3-AI.md).
type WorkoutStep struct {
	Key  string `json:"key"`
	Name string `json:"name"`
	// Mode is count (Target reps) or time (Target seconds).
	Mode    string `json:"mode"`
	Target  int    `json:"target"`
	RestSec int    `json:"rest_sec"`
	Sets    int    `json:"sets"`
	// Pose tells the app which on-device counting rule to use:
	// jump | squat | pushup | crunch | none.
	Pose    string  `json:"pose"`
	Cue     string  `json:"cue"`
	DemoURL *string `json:"demo_url"`
}

// Workout is a guided home-training routine.
type Workout struct {
	Key        string        `json:"key"`
	Name       string        `json:"name"`
	Sport      Sport         `json:"sport"`
	Level      string        `json:"level"`
	CoverURL   *string       `json:"cover_url"`
	EstMinutes int           `json:"est_minutes"`
	Camera     bool          `json:"camera"`
	Steps      []WorkoutStep `json:"steps"`
}

// AISettings tune the AI features.
type AISettings struct {
	// RouteMaxKm caps the length of suggested routes.
	RouteMaxKm float64 `json:"route_max_km"`
	// ReportMaxChars caps the battle report.
	ReportMaxChars int `json:"report_max_chars"`
	// ChatHistoryTurns is how many earlier question/answer pairs the
	// assistant sees.
	ChatHistoryTurns int `json:"chat_history_turns"`
}

func defaultAI() AISettings {
	return AISettings{RouteMaxKm: 15, ReportMaxChars: 120, ChatHistoryTurns: 6}
}

// DefaultWorkouts are the four launch routines.
func DefaultWorkouts() []Workout {
	step := func(key, name, mode string, target, rest, sets int, pose, cue string) WorkoutStep {
		return WorkoutStep{Key: key, Name: name, Mode: mode, Target: target, RestSec: rest, Sets: sets, Pose: pose, Cue: cue}
	}
	return []Workout{
		{Key: "rope_basic", Name: "跳绳入门", Sport: SportRope, Level: "beginner", EstMinutes: 12, Camera: true, Steps: []WorkoutStep{
			step("rope_jump", "双脚跳", "count", 100, 30, 5, "jump", "保持节奏，落地轻一点"),
			step("rope_alternate", "左右交替跳", "count", 60, 30, 2, "jump", "像原地慢跑一样换脚"),
		}},
		{Key: "hiit_burn", Name: "HIIT 燃脂", Sport: SportHIIT, Level: "intermediate", EstMinutes: 16, Camera: true, Steps: []WorkoutStep{
			step("jumping_jack", "开合跳", "time", 40, 20, 3, "jump", "手脚同时打开，核心收紧"),
			step("squat", "深蹲", "count", 15, 20, 3, "squat", "膝盖对准脚尖，臀部向后坐"),
			step("pushup", "俯卧撑", "count", 10, 30, 3, "pushup", "身体成一条直线，做不动可以跪姿"),
			step("high_knees", "高抬腿", "time", 30, 30, 3, "none", "大腿抬到水平，快速交替"),
		}},
		{Key: "pilates_core", Name: "普拉提核心", Sport: SportYoga, Level: "beginner", EstMinutes: 18, Camera: true, Steps: []WorkoutStep{
			step("crunch", "卷腹", "count", 15, 20, 3, "crunch", "下背贴地，用腹部发力"),
			step("plank", "平板支撑", "time", 40, 20, 3, "none", "肩在手肘正上方，别塌腰"),
			step("glute_bridge", "臀桥", "count", 15, 20, 3, "none", "臀部发力抬起，顶峰停一秒"),
		}},
		{Key: "strength_basic", Name: "力量入门", Sport: SportStrength, Level: "beginner", EstMinutes: 20, Camera: true, Steps: []WorkoutStep{
			step("squat", "徒手深蹲", "count", 15, 30, 4, "squat", "吸气下蹲，呼气起身"),
			step("pushup", "俯卧撑", "count", 10, 30, 3, "pushup", "下放慢一点，推起快一点"),
			step("lunge", "弓步蹲", "time", 40, 20, 3, "none", "前后脚都成 90 度"),
			step("crunch", "卷腹", "count", 20, 20, 3, "crunch", "别用手拉脖子"),
		}},
	}
}

var (
	workoutSports = map[Sport]bool{SportRope: true, SportHIIT: true, SportYoga: true, SportStrength: true}
	workoutLevels = map[string]bool{"beginner": true, "intermediate": true, "advanced": true}
	workoutPoses  = map[string]bool{"jump": true, "squat": true, "pushup": true, "crunch": true, "none": true}
)

// Workout looks up a routine by key.
func (c Config) Workout(key string) (Workout, bool) {
	for _, w := range c.Workouts {
		if w.Key == key {
			return w, true
		}
	}
	return Workout{}, false
}

// normalizeAI fills the sections for configurations stored before them.
func (c *Config) normalizeAI() {
	if c.Workouts == nil {
		c.Workouts = DefaultWorkouts()
	}
	if c.AI == (AISettings{}) {
		c.AI = defaultAI()
	}
}

func (c Config) validateAI() error {
	a := c.AI
	if a.RouteMaxKm <= 0 || a.RouteMaxKm > 100 {
		return fmt.Errorf("ai: route_max_km 应在 0–100 之间")
	}
	if a.ReportMaxChars < 20 || a.ReportMaxChars > 500 {
		return fmt.Errorf("ai: report_max_chars 应在 20–500 之间")
	}
	if a.ChatHistoryTurns < 0 || a.ChatHistoryTurns > 20 {
		return fmt.Errorf("ai: chat_history_turns 应在 0–20 之间")
	}
	seen := map[string]bool{}
	for _, w := range c.Workouts {
		if w.Key == "" || seen[w.Key] {
			return fmt.Errorf("workouts: key 为空或重复：%q", w.Key)
		}
		seen[w.Key] = true
		if !workoutSports[w.Sport] {
			return fmt.Errorf("workout %s: sport 只能是 rope / hiit / yoga / strength", w.Key)
		}
		if !workoutLevels[w.Level] {
			return fmt.Errorf("workout %s: level 取值错误", w.Key)
		}
		if w.Name == "" || w.EstMinutes <= 0 || len(w.Steps) == 0 {
			return fmt.Errorf("workout %s: 名称、时长、动作不能为空", w.Key)
		}
		for _, s := range w.Steps {
			if s.Key == "" || s.Name == "" || (s.Mode != "count" && s.Mode != "time") || s.Target <= 0 || s.Sets < 1 || s.RestSec < 0 || !workoutPoses[s.Pose] {
				return fmt.Errorf("workout %s: 动作 %q 不合法（mode count/time、target>0、sets≥1、pose jump/squat/pushup/crunch/none）", w.Key, s.Key)
			}
		}
	}
	return nil
}
