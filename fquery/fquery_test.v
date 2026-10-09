// Contract tests: every chain shape used by queries.py/ops.py compiles to
// the same parameterized SQL here as in Python, and runs against sqlite.
module fquery

import db.sqlite

// Test nodes mirror the campfile tables (compile-time table/alias mapping).
@[table: 'users']
@[node]
struct TUser {
	id              int
	name            string
	email_address   string
	password_digest string
	role            int
	status          int
	bio             string
}

@[table: 'rooms']
@[node]
struct TRoom {
	id         int
	name       string
	room_type  string @[col: 'type']
	creator_id int
}

@[table: 'memberships']
@[node]
struct TMembership {
	id           int
	room_id      int
	user_id      int
	involvement  string
	connected_at string
	unread_at    string
}

@[table: 'messages']
@[node]
struct TMessage {
	id                int
	room_id           int
	creator_id        int
	client_message_id string
	created_at        string
}

@[table: 'action_text_rich_texts']
@[alias: 'rich']
@[node]
struct TRich {
	id          int
	record_type string
	record_id   int
	name        string
	body        string
}

@[table: 'boosts']
@[alias: 'boost']
@[node]
struct TBoost {
	id         int
	message_id int
	content    string
}

@[table: 'message_mentions']
@[alias: 'mm']
@[node]
struct TMention {
	id         int
	message_id int
	user_id    int
}

@[table: 'message_search_index']
@[alias: 'idx']
@[node]
struct TFts {
	body string
}

fn member_chain() Query[TMembership] {
	return new_query[TMembership]().where(pred('membership.room_id == param("rid") and membership.user_id == param("uid")')).take(1).project([
		'membership.id',
	]).bind({
		'rid': 3
		'uid': 7
	})
}

fn test_member_check_sql() {
	b := member_chain().to_sql()!
	assert b.statement == 'SELECT "membership"."id" FROM "memberships" "membership" WHERE ("membership"."room_id"=? AND "membership"."user_id"=?) LIMIT 1'
	assert b.params == ['3', '7']
}

fn test_in_list_sql() {
	b := new_query[TUser]().where(pred('user.id in [1, 2, 3]')).project([
		'user.id',
		'user.name',
	]).to_sql()!
	assert b.statement == 'SELECT "user"."id", "user"."name" FROM "users" "user" WHERE "user"."id" IN (?,?,?)'
	assert b.params == ['1', '2', '3']
}

fn test_sidebar_sql() {
	b := new_query[TMembership]().where(pred('membership.user_id == param("uid") and membership.involvement != param("inv")')).edge(edge_to[TMembership, TRoom]('room',
		join_on('room_id', 'id'))).order_by(order('lower(room.name), room.id')).project([
		'membership.involvement',
		'membership.unread_at',
		'room.id',
		'room.name',
		'room.type',
	]).bind({
		'uid': 5
		'inv': 'invisible'
	}).to_sql()!
	assert b.statement == 'SELECT "membership"."involvement", "membership"."unread_at", "room"."id", "room"."name", "room"."type" FROM "memberships" "membership" JOIN "rooms" "room" ON "membership"."room_id"="room"."id" WHERE ("membership"."user_id"=? AND "membership"."involvement"<>?) ORDER BY LOWER("room"."name"),"room"."id"'
	assert b.params == ['5', 'invisible']
}

fn test_count_sql() {
	b := new_query[TMessage]().where(pred('message.room_id == param("rid")')).count().bind({
		'rid': 9
	}).to_sql()!
	assert b.statement == 'SELECT COUNT(*) FROM "messages" "message" WHERE "message"."room_id"=?'
	assert b.params == ['9']
}

fn test_mention_edge_sql() {
	b := new_query[TMention]().edge(edge_to[TMention, TUser]('user', join_on('user_id', 'id'))).where(pred('mm.message_id in [11, 12]')).project([
		'mm.message_id',
		'user.name',
	]).to_sql()!
	assert b.statement == 'SELECT "mm"."message_id", "user"."name" FROM "message_mentions" "mm" JOIN "users" "user" ON "mm"."user_id"="user"."id" WHERE "mm"."message_id" IN (?,?)'
	assert b.params == ['11', '12']
}

fn test_rich_body_sql() {
	b := new_query[TRich]().where(pred('rich.record_id in [1,2,3] and rich.name == param("n") and rich.record_type in ["Message", "ActionText::RichText"]')).order_by(order('rich.id')).project([
		'rich.record_id',
		'rich.body',
	]).bind({
		'n': 'body'
	}).to_sql()!
	assert b.statement == 'SELECT "rich"."record_id", "rich"."body" FROM "action_text_rich_texts" "rich" WHERE ("rich"."record_id" IN (?,?,?) AND "rich"."name"=? AND "rich"."record_type" IN (?,?)) ORDER BY "rich"."id"'
	assert b.params == ['1', '2', '3', 'body', 'Message', 'ActionText::RichText']
}

fn test_page_window_sql() {
	b := new_query[TMessage]().where(pred('message.room_id == param("rid") and (message.created_at > param("ts") or (message.created_at == param("ts") and message.id > param("mid")))')).order_by(order('message.created_at, message.id')).take(40).project([
		'message.id',
		'message.created_at',
	]).bind({
		'rid': 1
		'ts':  '2024-01-01 00:00:00.000000'
		'mid': 8
	}).to_sql()!
	assert b.statement == 'SELECT "message"."id", "message"."created_at" FROM "messages" "message" WHERE ("message"."room_id"=? AND ("message"."created_at">? OR ("message"."created_at"=? AND "message"."id">?))) ORDER BY "message"."created_at","message"."id" LIMIT 40'
	assert b.params == ['1', '2024-01-01 00:00:00.000000', '2024-01-01 00:00:00.000000', '8']
}

fn test_desc_order_sql() {
	b := new_query[TMessage]().where(pred('message.room_id == param("rid")')).order_by(order('desc(message.created_at), desc(message.id)')).take(40).project([
		'message.id',
	]).bind({
		'rid': 1
	}).to_sql()!
	assert b.statement == 'SELECT "message"."id" FROM "messages" "message" WHERE "message"."room_id"=? ORDER BY "message"."created_at" DESC,"message"."id" DESC LIMIT 40'
}

fn test_fts_sql() {
	b := new_query[TFts]().edge(edge_to[TFts, TMessage]('messages', join_on('rowid', 'id'))).where(pred('match(idx.body, param("q")) and message.room_id in [2, 3]')).order_by(order('message.created_at')).take(20).project([
		'message.id',
		'message.room_id',
	]).bind({
		'q': 'deploy friday'
	}).to_sql()!
	assert b.statement == 'SELECT "message"."id", "message"."room_id" FROM "message_search_index" "idx" JOIN "messages" "message" ON "idx"."rowid"="message"."id" WHERE ("idx"."body" MATCH ? AND "message"."room_id" IN (?,?)) ORDER BY "message"."created_at" LIMIT 20'
	assert b.params == ['deploy friday', '2', '3']
}

fn test_like_lower_sql() {
	b := new_query[TRoom]().where(pred('like(lower(room.name), param("q"))')).project([
		'room.id',
	]).bind({
		'q': '%eng%'
	}).to_sql()!
	assert b.statement == 'SELECT "room"."id" FROM "rooms" "room" WHERE LOWER("room"."name") LIKE ?'
	assert b.params == ['%eng%']
}

fn test_auth_lookup_sql() {
	b := new_query[TUser]().where(pred('user.email_address == param("email")')).take(1).project([
		'user.id',
		'user.name',
		'user.email_address',
		'user.password_digest',
		'user.role',
		'user.status',
		'user.bio',
	]).bind({
		'email': 'amy@example.com'
	}).to_sql()!
	assert b.statement == 'SELECT "user"."id", "user"."name", "user"."email_address", "user"."password_digest", "user"."role", "user"."status", "user"."bio" FROM "users" "user" WHERE "user"."email_address"=? LIMIT 1'
	assert b.params == ['amy@example.com']
}

fn test_col_attr_mapping() {
	assert columns_of[TRoom]() == ['id', 'name', 'type', 'creator_id']
	// room.type validates (the SQL column); the V field name does not.

	new_query[TRoom]().where(pred('room.type == param("t")')).project([
		'room.id',
	]).bind({
		't': 'Rooms::Open'
	}).to_sql()!
	bad := new_query[TRoom]().where(pred('room.room_type == param("t")')).project([
		'room.id',
	]).bind({
		't': 'Rooms::Open'
	})
	if _ := bad.to_sql() {
		assert false, 'expected room.room_type to be rejected'
	} else {
		assert err.msg().contains('room.room_type')
	}
}

fn test_missing_param_errors() {
	q := new_query[TUser]().where(pred('user.email_address == param("email")')).project([
		'user.id',
	])
	if _ := q.to_sql() {
		assert false, 'expected a missing-param error'
	} else {
		assert err.msg().contains('email')
	}
}

fn test_unknown_alias_errors() {
	q := new_query[TUser]().where(pred('nope.id == 1')).project(['user.id'])
	if _ := q.to_sql() {
		assert false, 'expected an unknown-alias error'
	} else {
		assert err.msg().contains('nope')
	}
}

fn test_unknown_column_errors() {
	q := new_query[TUser]().where(pred('user.nope == 1')).project(['user.id'])
	if _ := q.to_sql() {
		assert false, 'expected an unknown-column error'
	} else {
		assert err.msg().contains('user.nope')
	}
}

fn test_bad_predicate_errors() {
	q := new_query[TUser]().where(pred('user.id === 1')).project(['user.id'])
	if _ := q.to_sql() {
		assert false, 'expected a parse error'
	} else {
		assert err.msg().contains('fquery')
	}
}

// --- live round-trips -------------------------------------------------------

fn seed_db() !sqlite.DB {
	mut db := sqlite.connect(':memory:')!
	db.exec('create table users (id integer primary key, name text, email_address text)')!
	db.exec("insert into users (id, name, email_address) values (7, 'amy', 'amy@example.com')")!
	db.exec("insert into users (id, name, email_address) values (8, 'bo', 'bo@example.com')")!
	db.exec('create table rooms (id integer primary key, name text, type text)')!
	db.exec("insert into rooms (id, name, type) values (3, 'Eng', 'Rooms::Open')")!
	db.exec("insert into rooms (id, name, type) values (4, 'Zebra', 'Rooms::Closed')")!
	db.exec('create table memberships (id integer primary key, room_id integer, user_id integer, involvement text, unread_at integer)')!
	db.exec("insert into memberships (id, room_id, user_id, involvement, unread_at) values (1, 3, 7, 'mentions', 0)")!
	db.exec("insert into memberships (id, room_id, user_id, involvement, unread_at) values (2, 4, 7, 'everything', 1700000000)")!
	db.exec("insert into memberships (id, room_id, user_id, involvement, unread_at) values (3, 3, 8, 'invisible', 0)")!
	db.exec('create table messages (id integer primary key, room_id integer, creator_id integer, client_message_id text, created_at text)')!
	db.exec("insert into messages (id, room_id, creator_id, client_message_id, created_at) values (11, 3, 7, 'c-11', '2024-05-01 10:00:00.000000')")!
	db.exec("insert into messages (id, room_id, creator_id, client_message_id, created_at) values (12, 3, 8, 'c-12', '2024-05-01 10:01:00.000000')")!
	return db
}

fn test_member_true_and_false() {
	mut db := seed_db()!
	yes := new_query[TMembership]().where(pred('membership.room_id == param("rid") and membership.user_id == param("uid")')).take(1).project([
		'membership.id',
	]).bind({
		'rid': 3
		'uid': 7
	}).to_rows(&db)!
	assert yes.len == 1
	assert yes[0]['id'] == '1'
	no := new_query[TMembership]().where(pred('membership.room_id == param("rid") and membership.user_id == param("uid")')).take(1).project([
		'membership.id',
	]).bind({
		'rid': 4
		'uid': 8
	}).to_rows(&db)!
	assert no.len == 0
}

fn test_sidebar_round_trip() {
	mut db := seed_db()!
	rows := new_query[TMembership]().where(pred('membership.user_id == param("uid") and membership.involvement != param("inv")')).edge(edge_to[TMembership, TRoom]('room',
		join_on('room_id', 'id'))).order_by(order('lower(room.name), room.id')).project([
		'membership.involvement',
		'membership.unread_at',
		'room.id',
		'room.name',
		'room.type',
	]).bind({
		'uid': 7
		'inv': 'invisible'
	}).to_rows(&db)!
	assert rows.len == 2
	assert rows[0]['name'] == 'Eng'
	assert rows[1]['name'] == 'Zebra'
	assert rows[0]['involvement'] == 'mentions'
}

fn test_count_round_trip() {
	mut db := seed_db()!
	rows := new_query[TMessage]().where(pred('message.room_id == param("rid")')).count().bind({
		'rid': 3
	}).to_rows(&db)!
	assert count_value(rows) == 2
}

fn test_typed_decode() {
	mut db := seed_db()!
	got := new_query[TUser]().where(pred('user.id == param("id")')).take(1).project([
		'user.id',
		'user.name',
		'user.email_address',
	]).bind({
		'id': 7
	}).to_structs(&db)!
	assert got.len == 1
	assert got[0].id == 7
	assert got[0].name == 'amy'
	assert got[0].email_address == 'amy@example.com'
}

fn test_ambient_connection() {
	mut db := seed_db()!
	use_db(db)
	rows := new_query[TUser]().where(pred('user.id == param("id")')).project([
		'user.id',
		'user.name',
	]).bind({
		'id': 8
	}).rows()!
	assert rows.len == 1
	assert rows[0]['name'] == 'bo'
}

// Edge declarations under test (mirror fq.py stubs).
@[edge]
fn (m TMembership) room() []TRoom {
	return []TRoom{}
}

@[edge]
fn (m TMention) user() []TUser {
	return []TUser{}
}

@[edge]
fn (f TFts) messages() []TMessage {
	return []TMessage{}
}

struct TPlain {
	id int
}

fn test_non_node_rejected() {
	q := new_query[TPlain]()
	if _ := q.to_sql() {
		assert false, 'expected a non-node error'
	} else {
		assert err.msg().contains('not a @[node]')
	}
}

fn test_undeclared_edge_errors() {
	q := new_query[TMembership]().edge(edge_to[TMembership, TRoom]('rooms',
		join_on('room_id', 'id'))).project([
		'membership.id',
	])
	if _ := q.to_sql() {
		assert false, 'expected an undeclared-edge error'
	} else {
		assert err.msg().contains('no @[edge] `rooms`')
		assert err.msg().contains('room')
	}
}

fn test_wrong_edge_target_errors() {
	q := new_query[TMembership]().edge(edge_to[TMembership, TUser]('room', join_on('room_id', 'id'))).project([
		'membership.id',
	])
	if _ := q.to_sql() {
		assert false, 'expected a wrong-target error'
	} else {
		assert err.msg().contains('does not target')
	}
}

fn test_dump() {
	d := member_chain().dump()
	assert d.contains('LEAF memberships AS membership')
	assert d.contains('WHERE membership.room_id == param("rid") and membership.user_id == param("uid")')
	assert d.contains('TAKE 1')
	assert d.contains('PROJECT membership.id')
}

fn test_typed_decode_second_type() {
	mut db := seed_db()!
	got := new_query[TRoom]().where(pred('room.id == param("id")')).project([
		'room.id',
		'room.name',
		'room.type',
	]).bind({
		'id': 3
	}).to_structs(&db)!
	assert got.len == 1
	assert got[0].id == 3
	assert got[0].name == 'Eng'
	assert got[0].room_type == 'Rooms::Open'
}
