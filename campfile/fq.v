// campfile query bindings: node declarations for every model.
//
// V port of src/campfile/fq.py. Each @node dataclass becomes a struct
// whose [table]/[alias] attributes declare the SQL mapping; each
// make_query_type() call becomes a new_*_query() constructor. The Python
// @edge methods (graph traversal) are not needed for SQL chains: the
// transpiler fills the edge target type from the @edge return annotation,
// so `.edge('room', ...)` becomes `.edge[Room]('room', ...)` — checked at
// compile time instead of via the runtime EDGE_NAME_TO_RETURN_TYPE map.
module campfile

import fquery

// ---------------------------------------------------------------------------
// Nodes (field lists cover every alias.col referenced by queries.py/ops.py)
// ---------------------------------------------------------------------------

@[table: 'users']
@[node]
pub struct User {
pub mut:
	id              int
	name            string
	email_address   string
	password_digest string
	bio             string
	bot_token       string
	role            int
	status          int
	created_at      string
	updated_at      string
}

@[table: 'rooms']
@[node]
pub struct Room {
pub mut:
	id   int
	name string
	// Rails STI string ('Rooms::Open', ...); the int kind lives in views.
	// `type` is a V keyword, so the field-level @[col] attr names the column.
	room_type  string @[col: 'type']
	creator_id int
	created_at string
	updated_at string
}

@[table: 'memberships']
@[node]
pub struct Membership {
pub mut:
	id           int
	room_id      int
	user_id      int
	involvement  string
	connections  int
	connected_at string
	unread_at    string
	created_at   string
	updated_at   string
}

// RoomWithMembershipsQuery reads rooms under the `room` alias so chains
// can join memberships without alias collision (mirrors the Python ALIAS).
@[table: 'rooms']
@[alias: 'room']
@[node]
pub struct RoomWithMemberships {
pub mut:
	id         int
	name       string
	room_type  string @[col: 'type']
	creator_id int
	created_at string
	updated_at string
}

@[table: 'messages']
@[node]
pub struct Message {
pub mut:
	id                int
	room_id           int
	creator_id        int
	client_message_id string
	created_at        string
	updated_at        string
}

@[table: 'action_text_rich_texts']
@[alias: 'rich']
@[node]
pub struct RichText {
pub mut:
	id          int
	record_type string
	record_id   int
	name        string
	body        string
	created_at  string
	updated_at  string
}

@[table: 'message_mentions']
@[alias: 'mm']
@[node]
pub struct MessageMention {
pub mut:
	id         int
	message_id int
	user_id    int
}

@[table: 'bans']
@[node]
pub struct Ban {
pub mut:
	id         int
	user_id    int
	ip_address string
	created_at string
}

@[table: 'boosts']
@[alias: 'boost']
@[node]
pub struct Boost {
pub mut:
	id         int
	message_id int
	booster_id int
	content    string
	created_at string
	updated_at string
}

@[table: 'sessions']
@[alias: 'sess']
@[node]
pub struct UserSession {
pub mut:
	id             int
	user_id        int
	token          string
	ip_address     string
	user_agent     string
	last_active_at string
	created_at     string
	updated_at     string
}

@[table: 'searches']
@[alias: 'search']
@[node]
pub struct SearchRecord {
pub mut:
	id         int
	user_id    int
	query      string
	created_at string
	updated_at string
}

@[table: 'push_subscriptions']
@[alias: 'push']
@[node]
pub struct PushSubscription {
pub mut:
	id         int
	user_id    int
	endpoint   string
	p256dh_key string
	auth_key   string
	user_agent string
	created_at string
	updated_at string
}

@[table: 'webhooks']
@[node]
pub struct Webhook {
pub mut:
	id         int
	user_id    int
	url        string
	created_at string
	updated_at string
}

@[table: 'accounts']
@[node]
pub struct Account {
pub mut:
	id         int
	name       string
	settings   string
	created_at string
	updated_at string
}

@[table: 'message_search_index']
@[alias: 'idx']
@[node]
pub struct Fts {
pub mut:
	body string
}

// ---------------------------------------------------------------------------
// Query constructors (mirrors the _qt(...) assignments in fq.py)
// ---------------------------------------------------------------------------

pub fn new_user_query() fquery.Query[User] {
	return fquery.new_query[User]()
}

pub fn new_room_query() fquery.Query[Room] {
	return fquery.new_query[Room]()
}

pub fn new_membership_query() fquery.Query[Membership] {
	return fquery.new_query[Membership]()
}

pub fn new_room_with_memberships_query() fquery.Query[RoomWithMemberships] {
	return fquery.new_query[RoomWithMemberships]()
}

pub fn new_message_query() fquery.Query[Message] {
	return fquery.new_query[Message]()
}

pub fn new_rich_text_query() fquery.Query[RichText] {
	return fquery.new_query[RichText]()
}

pub fn new_message_mention_query() fquery.Query[MessageMention] {
	return fquery.new_query[MessageMention]()
}

pub fn new_ban_query() fquery.Query[Ban] {
	return fquery.new_query[Ban]()
}

pub fn new_boost_query() fquery.Query[Boost] {
	return fquery.new_query[Boost]()
}

pub fn new_user_session_query() fquery.Query[UserSession] {
	return fquery.new_query[UserSession]()
}

pub fn new_search_record_query() fquery.Query[SearchRecord] {
	return fquery.new_query[SearchRecord]()
}

pub fn new_push_subscription_query() fquery.Query[PushSubscription] {
	return fquery.new_query[PushSubscription]()
}

pub fn new_webhook_query() fquery.Query[Webhook] {
	return fquery.new_query[Webhook]()
}

pub fn new_account_query() fquery.Query[Account] {
	return fquery.new_query[Account]()
}

pub fn new_fts_query() fquery.Query[Fts] {
	return fquery.new_query[Fts]()
}

// ---------------------------------------------------------------------------
// Edges (mirror the @edge methods in fq.py).
//
// Like their Python originals (`yield []` stubs), these bodies never run:
// they declare the graph — edge name to target node type — so chains can
// resolve `.edge("room", ...)` the way fquery resolves it via
// EDGE_NAME_TO_RETURN_TYPE. The transpiler maps
//   @edge
//   async def room(self) -> List["RoomNode"]: yield []
// to
//   @[edge]
//   fn (m Membership) room() []Room { return []Room{} }
// and `Query.edge[U]` validates `name` + `U` against them at compile time.
// (In-memory traversal of these edges — materialize_walk — is a future
// backend over the same chain IR, not implemented here.)
// ---------------------------------------------------------------------------

@[edge]
fn (m Membership) room() []Room {
	return []Room{}
}

@[edge]
fn (r RoomWithMemberships) memberships() []Membership {
	return []Membership{}
}

@[edge]
fn (m MessageMention) user() []User {
	return []User{}
}

@[edge]
fn (f Fts) messages() []Message {
	return []Message{}
}
