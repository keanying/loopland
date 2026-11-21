package community

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"

	"github.com/keanying/loopland/server/internal/media"
	"github.com/keanying/loopland/server/internal/moderation"
	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/platform/httpx"
	"github.com/keanying/loopland/server/internal/realtime"
)

// Chat limits.
const (
	maxTextRunes   = 500
	strangerLimit  = 3
	chatPerMinute  = 30
	messagePageDef = 30
)

// Ref points a group chat at its source.
type Ref struct {
	Type string `json:"type"`
	ID   int64  `json:"id"`
}

// Message is a chat message.
type Message struct {
	ID             int64           `json:"id"`
	ConversationID int64           `json:"conversation_id"`
	Sender         *UserBrief      `json:"sender"`
	Type           string          `json:"type"`
	Content        string          `json:"content"`
	Payload        json.RawMessage `json:"payload"`
	CreatedAt      time.Time       `json:"created_at"`

	senderID *int64
}

// Conversation is a direct or group chat as one member sees it.
type Conversation struct {
	ID          int64      `json:"id"`
	Type        string     `json:"type"`
	Title       string     `json:"title"`
	AvatarURL   *string    `json:"avatar_url"`
	Peer        *UserBrief `json:"peer"`
	Ref         *Ref       `json:"ref"`
	LastMessage *Message   `json:"last_message"`
	UnreadCount int        `json:"unread_count"`
	Muted       bool       `json:"muted"`
	// PeerReadMessageID is how far the other person has read (direct
	// chats; 0 for groups), for 已读 receipts.
	PeerReadMessageID int64     `json:"peer_read_message_id"`
	UpdatedAt         time.Time `json:"updated_at"`
}

const messageCols = `id, conversation_id, sender_id, message_type, content, payload_json, create_time`

func scanMessages(rows pgx.Rows) ([]Message, error) {
	return pgx.CollectRows(rows, func(r pgx.CollectableRow) (Message, error) {
		var m Message
		var payload []byte
		err := r.Scan(&m.ID, &m.ConversationID, &m.senderID, &m.Type, &m.Content, &payload, &m.CreatedAt)
		m.Payload = payload
		return m, err
	})
}

// fillSenders sets Sender on each message.
func fillSenders(ctx context.Context, q db.Querier, ms []Message) error {
	var ids []int64
	for _, m := range ms {
		if m.senderID != nil {
			ids = append(ids, *m.senderID)
		}
	}
	bs, err := briefs(ctx, q, ids)
	if err != nil {
		return err
	}
	for i := range ms {
		if ms[i].senderID != nil {
			if b, ok := bs[*ms[i].senderID]; ok {
				ms[i].Sender = &b
			}
		}
	}
	return nil
}

// conversations loads the viewer's conversations matching where (which may
// use $1 = viewer and further args).
func conversations(ctx context.Context, q db.Querier, viewer int64, where, tail string, args ...any) ([]Conversation, error) {
	rows, err := q.Query(ctx, `SELECT c.id, c.conversation_type, COALESCE(c.title,''), c.avatar_url, c.ref_type, c.ref_id, c.last_message_id,
			cm.is_muted, COALESCE(c.last_message_time, c.create_time),
			(SELECT count(*) FROM src.src_msg_loop_message m WHERE m.conversation_id=c.id AND m.id > cm.last_read_message_id
				AND m.sender_id IS DISTINCT FROM $1),
			(SELECT p.user_id FROM src.src_msg_loop_conv_member p WHERE p.conversation_id=c.id AND p.user_id<>$1 AND c.conversation_type='direct' LIMIT 1),
			COALESCE((SELECT p.last_read_message_id FROM src.src_msg_loop_conv_member p WHERE p.conversation_id=c.id AND p.user_id<>$1 AND c.conversation_type='direct' LIMIT 1), 0)
		FROM src.src_msg_loop_conv_member cm JOIN src.src_msg_loop_conversation c ON c.id=cm.conversation_id
		WHERE cm.user_id=$1 AND `+where+` `+tail, append([]any{viewer}, args...)...)
	if err != nil {
		return nil, err
	}
	type row struct {
		c      Conversation
		refT   *string
		refID  *int64
		lastID *int64
		peer   *int64
	}
	rs, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (row, error) {
		var x row
		err := r.Scan(&x.c.ID, &x.c.Type, &x.c.Title, &x.c.AvatarURL, &x.refT, &x.refID, &x.lastID, &x.c.Muted, &x.c.UpdatedAt, &x.c.UnreadCount, &x.peer, &x.c.PeerReadMessageID)
		return x, err
	})
	if err != nil {
		return nil, err
	}
	var lastIDs, peers []int64
	for _, x := range rs {
		if x.lastID != nil {
			lastIDs = append(lastIDs, *x.lastID)
		}
		if x.peer != nil {
			peers = append(peers, *x.peer)
		}
	}
	last := map[int64]Message{}
	if len(lastIDs) > 0 {
		mrows, err := q.Query(ctx, `SELECT `+messageCols+` FROM src.src_msg_loop_message WHERE id = ANY($1)`, lastIDs)
		if err != nil {
			return nil, err
		}
		ms, err := scanMessages(mrows)
		if err != nil {
			return nil, err
		}
		if err := fillSenders(ctx, q, ms); err != nil {
			return nil, err
		}
		for _, m := range ms {
			last[m.ID] = m
		}
	}
	pb, err := briefs(ctx, q, peers)
	if err != nil {
		return nil, err
	}
	out := make([]Conversation, 0, len(rs))
	for _, x := range rs {
		c := x.c
		if x.refT != nil && x.refID != nil {
			c.Ref = &Ref{Type: *x.refT, ID: *x.refID}
		}
		if x.lastID != nil {
			if m, ok := last[*x.lastID]; ok {
				c.LastMessage = &m
			}
		}
		if x.peer != nil {
			if b, ok := pb[*x.peer]; ok {
				c.Peer = &b
				c.Title, c.AvatarURL = b.Nickname, b.AvatarURL
			}
		}
		out = append(out, c)
	}
	return out, nil
}

func conversation(ctx context.Context, q db.Querier, viewer, id int64) (Conversation, error) {
	cs, err := conversations(ctx, q, viewer, `c.id=$2`, ``, id)
	if err != nil {
		return Conversation{}, err
	}
	if len(cs) == 0 {
		return Conversation{}, errNotMember
	}
	return cs[0], nil
}

// Conversation is GET /v1/conversations/{id}.
func (s *Service) Conversation(ctx context.Context, viewer, id int64) (Conversation, error) {
	return conversation(ctx, s.Pool, viewer, id)
}

// ListConversations is GET /v1/conversations.
func (s *Service) ListConversations(ctx context.Context, viewer int64, c cursor) (CursorList[Conversation], error) {
	cs, err := conversations(ctx, s.Pool, viewer, `NOT cm.is_hidden`,
		`ORDER BY COALESCE(c.last_message_time, c.create_time) DESC, c.id DESC LIMIT $2 OFFSET $3`, c.limit+1, c.offset)
	if err != nil {
		return CursorList[Conversation]{}, err
	}
	return page(cs, c), nil
}

// OpenDirect is POST /v1/conversations/direct: returns the existing
// conversation with peer or creates it (hidden for the peer until the
// first message).
func (s *Service) OpenDirect(ctx context.Context, user, peer int64) (Conversation, error) {
	if peer == user {
		return Conversation{}, httpx.BadRequest("invalid_target", "不能给自己发私信")
	}
	var status string
	err := s.Pool.QueryRow(ctx, `SELECT status FROM src.src_usr_loop_user WHERE id=$1`, peer).Scan(&status)
	if db.IsNoRows(err) || status == "deleted" {
		return Conversation{}, httpx.NotFound("用户")
	}
	if err != nil {
		return Conversation{}, err
	}
	if b, err := blockedEither(ctx, s.Pool, user, peer); err != nil {
		return Conversation{}, err
	} else if b {
		return Conversation{}, errBlocked
	}
	key := fmt.Sprintf("%d:%d", min(user, peer), max(user, peer))
	var id int64
	err = pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		err := tx.QueryRow(ctx, `INSERT INTO src.src_msg_loop_conversation (conversation_type, direct_key) VALUES ('direct', $1)
			ON CONFLICT (direct_key) DO UPDATE SET direct_key=EXCLUDED.direct_key RETURNING id`, key).Scan(&id)
		if err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO src.src_msg_loop_conv_member (conversation_id, user_id) VALUES ($1,$2)
			ON CONFLICT (conversation_id, user_id) DO UPDATE SET is_hidden=false`, id, user); err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `INSERT INTO src.src_msg_loop_conv_member (conversation_id, user_id, is_hidden) VALUES ($1,$2,true)
			ON CONFLICT (conversation_id, user_id) DO NOTHING`, id, peer)
		return err
	})
	if err != nil {
		return Conversation{}, err
	}
	return conversation(ctx, s.Pool, user, id)
}

// member describes the caller's place in a conversation.
type member struct {
	convType string
	refType  *string
	refID    *int64
	peer     *int64
}

func loadMember(ctx context.Context, q db.Querier, user, conv int64) (member, error) {
	var m member
	err := q.QueryRow(ctx, `SELECT c.conversation_type, c.ref_type, c.ref_id,
			(SELECT p.user_id FROM src.src_msg_loop_conv_member p WHERE p.conversation_id=c.id AND p.user_id<>$1 AND c.conversation_type='direct' LIMIT 1)
		FROM src.src_msg_loop_conv_member cm JOIN src.src_msg_loop_conversation c ON c.id=cm.conversation_id
		WHERE cm.user_id=$1 AND cm.conversation_id=$2`, user, conv).Scan(&m.convType, &m.refType, &m.refID, &m.peer)
	if db.IsNoRows(err) {
		var exists bool
		if err := q.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM src.src_msg_loop_conversation WHERE id=$1)`, conv).Scan(&exists); err != nil {
			return m, err
		}
		if !exists {
			return m, httpx.NotFound("会话")
		}
		return m, errNotMember
	}
	return m, err
}

// Messages is GET /v1/conversations/{id}/messages (newest first).
func (s *Service) Messages(ctx context.Context, user, conv, before int64, limit int) (CursorList[Message], error) {
	if _, err := loadMember(ctx, s.Pool, user, conv); err != nil {
		return CursorList[Message]{}, err
	}
	if limit <= 0 || limit > 100 {
		limit = messagePageDef
	}
	rows, err := s.Pool.Query(ctx, `SELECT `+messageCols+` FROM src.src_msg_loop_message
		WHERE conversation_id=$1 AND ($2 = 0 OR id < $2) ORDER BY id DESC LIMIT $3`, conv, before, limit+1)
	if err != nil {
		return CursorList[Message]{}, err
	}
	ms, err := scanMessages(rows)
	if err != nil {
		return CursorList[Message]{}, err
	}
	out := CursorList[Message]{Items: ms}
	if len(ms) > limit {
		out.Items = ms[:limit]
		next := strconv.FormatInt(ms[limit-1].ID, 10)
		out.NextCursor = &next
	}
	if out.Items == nil {
		out.Items = []Message{}
	}
	return out, fillSenders(ctx, s.Pool, out.Items)
}

// SendInput is POST /v1/conversations/{id}/messages.
type SendInput struct {
	Type    string `json:"type"`
	Content string `json:"content"`
	ImageID int64  `json:"image_id"`
	PostID  int64  `json:"post_id"`
}

// Send posts a message after the block, stranger, mute, rate and content
// checks.
func (s *Service) Send(ctx context.Context, user, conv int64, in SendInput) (Message, error) {
	m, err := loadMember(ctx, s.Pool, user, conv)
	if err != nil {
		return Message{}, err
	}
	if mu, err := muted(ctx, s.Pool, user); err != nil {
		return Message{}, err
	} else if mu {
		return Message{}, errMuted
	}
	in.Content = strings.TrimSpace(in.Content)
	payload := map[string]any{}
	switch in.Type {
	case "", "text":
		in.Type = "text"
		if n := utf8.RuneCountInString(in.Content); n < 1 || n > maxTextRunes {
			return Message{}, httpx.BadRequest("invalid_body", "消息 1–500 字")
		}
		if sc := s.Mod.Check(ctx, in.Content, false); sc.Blocked || sc.Value >= moderation.ChatReject {
			return Message{}, moderation.ErrBlocked
		}
	case "image":
		ims, err := media.Owned(ctx, s.Pool, user, []int64{in.ImageID})
		if err != nil {
			return Message{}, err
		}
		payload = map[string]any{"url": ims[0].URL, "width": ims[0].Width, "height": ims[0].Height}
		in.Content = ""
	case "post":
		var ok bool
		if err := s.Pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM src.src_soc_loop_post WHERE id=$1 AND delete_time IS NULL)`, in.PostID).Scan(&ok); err != nil {
			return Message{}, err
		}
		if !ok {
			return Message{}, httpx.NotFound("动态")
		}
		payload = map[string]any{"post_id": in.PostID}
		in.Content = ""
	default:
		return Message{}, httpx.BadRequest("invalid_body", "type 取值错误")
	}
	if m.convType == "direct" && m.peer != nil {
		if b, err := blockedEither(ctx, s.Pool, user, *m.peer); err != nil {
			return Message{}, err
		} else if b {
			return Message{}, errBlocked
		}
		var allowed bool
		if err := s.Pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM src.src_soc_loop_follow WHERE follower_id=$2 AND followee_id=$1)
				OR EXISTS (SELECT 1 FROM src.src_msg_loop_message WHERE conversation_id=$3 AND sender_id=$2)
				OR (SELECT count(*) FROM src.src_msg_loop_message WHERE conversation_id=$3 AND sender_id=$1) < $4`,
			user, *m.peer, conv, strangerLimit).Scan(&allowed); err != nil {
			return Message{}, err
		}
		if !allowed {
			return Message{}, httpx.Forbidden("stranger_limit", "对方回复或关注你之前，最多发 3 条消息")
		}
	}
	if err := s.rateLimit(ctx, user); err != nil {
		return Message{}, err
	}
	var msg Message
	err = s.tx(ctx, func(tx pgx.Tx, evs *[]realtime.Event) error {
		var err error
		msg, err = post(ctx, tx, conv, &user, in.Type, in.Content, payload, evs)
		return err
	})
	return msg, err
}

// rateLimit allows chatPerMinute messages per user per minute.
func (s *Service) rateLimit(ctx context.Context, user int64) error {
	key := fmt.Sprintf("chat:rate:%d:%d", user, time.Now().Unix()/60)
	pipe := s.Redis.TxPipeline()
	n := pipe.Incr(ctx, key)
	pipe.Expire(ctx, key, 2*time.Minute)
	if _, err := pipe.Exec(ctx); err != nil {
		return err
	}
	if n.Val() > chatPerMinute {
		return httpx.ErrRateLimited
	}
	return nil
}

// post stores a message, bumps the conversation, shows it again for members
// who hid it, and queues the realtime event for every member.
func post(ctx context.Context, tx pgx.Tx, conv int64, sender *int64, typ, content string, payload map[string]any, evs *[]realtime.Event) (Message, error) {
	if payload == nil {
		payload = map[string]any{}
	}
	raw, _ := json.Marshal(payload)
	rows, err := tx.Query(ctx, `INSERT INTO src.src_msg_loop_message (conversation_id, sender_id, message_type, content, payload_json)
		VALUES ($1,$2,$3,$4,$5) RETURNING `+messageCols, conv, sender, typ, content, raw)
	if err != nil {
		return Message{}, err
	}
	ms, err := scanMessages(rows)
	if err != nil {
		return Message{}, err
	}
	msg := ms[0]
	if _, err := tx.Exec(ctx, `UPDATE src.src_msg_loop_conversation SET last_message_id=$2, last_message_time=$3, update_time=now() WHERE id=$1`,
		conv, msg.ID, msg.CreatedAt); err != nil {
		return msg, err
	}
	if _, err := tx.Exec(ctx, `UPDATE src.src_msg_loop_conv_member SET is_hidden=false WHERE conversation_id=$1 AND is_hidden`, conv); err != nil {
		return msg, err
	}
	if sender != nil {
		if _, err := tx.Exec(ctx, `UPDATE src.src_msg_loop_conv_member SET last_read_message_id=$3 WHERE conversation_id=$1 AND user_id=$2`,
			conv, *sender, msg.ID); err != nil {
			return msg, err
		}
	}
	if err := fillSenders(ctx, tx, ms); err != nil {
		return msg, err
	}
	msg = ms[0]
	users, err := members(ctx, tx, conv)
	if err != nil {
		return msg, err
	}
	*evs = append(*evs, realtime.NewEvent("", users, map[string]any{"type": "chat_message", "message": msg}))
	return msg, nil
}

func members(ctx context.Context, q db.Querier, conv int64) ([]int64, error) {
	rows, err := q.Query(ctx, `SELECT user_id FROM src.src_msg_loop_conv_member WHERE conversation_id=$1 ORDER BY user_id`, conv)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowTo[int64])
}

// Read is POST /v1/conversations/{id}/read.
func (s *Service) Read(ctx context.Context, user, conv, messageID int64) error {
	if _, err := loadMember(ctx, s.Pool, user, conv); err != nil {
		return err
	}
	return s.tx(ctx, func(tx pgx.Tx, evs *[]realtime.Event) error {
		var upTo int64
		err := tx.QueryRow(ctx, `UPDATE src.src_msg_loop_conv_member cm
			SET last_read_message_id=GREATEST(cm.last_read_message_id, LEAST($3, COALESCE(c.last_message_id, 0)))
			FROM src.src_msg_loop_conversation c WHERE c.id=cm.conversation_id AND cm.conversation_id=$1 AND cm.user_id=$2
			RETURNING cm.last_read_message_id`, conv, user, messageID).Scan(&upTo)
		if err != nil {
			return err
		}
		users, err := members(ctx, tx, conv)
		if err != nil {
			return err
		}
		*evs = append(*evs, realtime.NewEvent("", users, map[string]any{"type": "conversation_read", "conversation_id": conv,
			"user_id": user, "message_id": upTo}))
		return nil
	})
}

// Mute is POST /v1/conversations/{id}/mute.
func (s *Service) Mute(ctx context.Context, user, conv int64, on bool) error {
	if _, err := loadMember(ctx, s.Pool, user, conv); err != nil {
		return err
	}
	_, err := s.Pool.Exec(ctx, `UPDATE src.src_msg_loop_conv_member SET is_muted=$3 WHERE conversation_id=$1 AND user_id=$2`, conv, user, on)
	return err
}

// Delete is DELETE /v1/conversations/{id}: hides a direct chat, leaves a
// group (and the meetup or rally behind it).
func (s *Service) Delete(ctx context.Context, user, conv int64) error {
	m, err := loadMember(ctx, s.Pool, user, conv)
	if err != nil {
		return err
	}
	if m.convType == "direct" {
		_, err := s.Pool.Exec(ctx, `UPDATE src.src_msg_loop_conv_member cm SET is_hidden=true,
				last_read_message_id=GREATEST(cm.last_read_message_id, COALESCE(c.last_message_id, 0))
			FROM src.src_msg_loop_conversation c WHERE c.id=cm.conversation_id AND cm.conversation_id=$1 AND cm.user_id=$2`, conv, user)
		return err
	}
	if m.refType != nil && m.refID != nil {
		switch *m.refType {
		case "meetup":
			_, err := s.LeaveMeetup(ctx, user, *m.refID)
			return err
		case "rally":
			_, err := s.LeaveRally(ctx, user, *m.refID)
			return err
		}
	}
	return s.tx(ctx, func(tx pgx.Tx, evs *[]realtime.Event) error { return leaveGroup(ctx, tx, conv, user, evs) })
}

// createGroup makes the group chat of a meetup or rally with its owner.
func createGroup(ctx context.Context, tx pgx.Tx, title, refType string, refID, owner int64) (int64, error) {
	var id int64
	if err := tx.QueryRow(ctx, `INSERT INTO src.src_msg_loop_conversation (conversation_type, title, ref_type, ref_id) VALUES ('group',$1,$2,$3) RETURNING id`,
		title, refType, refID).Scan(&id); err != nil {
		return 0, err
	}
	_, err := tx.Exec(ctx, `INSERT INTO src.src_msg_loop_conv_member (conversation_id, user_id, member_role_type) VALUES ($1,$2,'owner')`, id, owner)
	return id, err
}

// joinGroup adds a member (history before joining does not count as
// unread) and announces it.
func joinGroup(ctx context.Context, tx pgx.Tx, conv, user int64, evs *[]realtime.Event) error {
	tag, err := tx.Exec(ctx, `INSERT INTO src.src_msg_loop_conv_member (conversation_id, user_id, last_read_message_id)
		SELECT $1, $2, COALESCE(last_message_id, 0) FROM src.src_msg_loop_conversation WHERE id=$1
		ON CONFLICT (conversation_id, user_id) DO NOTHING`, conv, user)
	if err != nil || tag.RowsAffected() == 0 {
		return err
	}
	b, err := brief(ctx, tx, user)
	if err != nil {
		return err
	}
	_, err = post(ctx, tx, conv, nil, "system", b.Nickname+" 加入了群聊", map[string]any{"event": "join", "user_id": user}, evs)
	return err
}

// leaveGroup removes a member and announces it.
func leaveGroup(ctx context.Context, tx pgx.Tx, conv, user int64, evs *[]realtime.Event) error {
	tag, err := tx.Exec(ctx, `DELETE FROM src.src_msg_loop_conv_member WHERE conversation_id=$1 AND user_id=$2`, conv, user)
	if err != nil || tag.RowsAffected() == 0 {
		return err
	}
	b, err := brief(ctx, tx, user)
	if err != nil {
		return err
	}
	_, err = post(ctx, tx, conv, nil, "system", b.Nickname+" 退出了群聊", map[string]any{"event": "leave", "user_id": user}, evs)
	return err
}

// ChatUnread is the unread total over the user's conversations that are
// not muted.
func ChatUnread(ctx context.Context, q db.Querier, user int64) (int, error) {
	var n int
	err := q.QueryRow(ctx, `SELECT COALESCE(sum((SELECT count(*) FROM src.src_msg_loop_message m
			WHERE m.conversation_id=cm.conversation_id AND m.id > cm.last_read_message_id AND m.sender_id IS DISTINCT FROM $1)), 0)
		FROM src.src_msg_loop_conv_member cm WHERE cm.user_id=$1 AND NOT cm.is_muted`, user).Scan(&n)
	return n, err
}

// RemoveMessage takes down a reported message (管理端举报处理): its text and
// payload are replaced by a system notice. It returns the original sender.
func (s *Service) RemoveMessage(ctx context.Context, tx pgx.Tx, id int64) (int64, error) {
	var sender *int64
	err := tx.QueryRow(ctx, `SELECT sender_id FROM src.src_msg_loop_message WHERE id=$1 FOR UPDATE`, id).Scan(&sender)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return 0, httpx.NotFound("消息")
		}
		return 0, err
	}
	if _, err := tx.Exec(ctx, `UPDATE src.src_msg_loop_message SET message_type='system', content='该消息因违反社区规范已被删除',
		payload_json=jsonb_build_object('event','removed') WHERE id=$1`, id); err != nil {
		return 0, err
	}
	if sender == nil {
		return 0, nil
	}
	return *sender, nil
}
