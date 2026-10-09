// In-memory backend tests: same chains as the SQL suite, folded over
// rows instead of rendered. Agreement tests run both backends on one
// seeded DB and require identical rows.
module fquery

import db.sqlite

@[table: 'users']
@[node]
struct MUser {
	id   int
	name string
}

@[table: 'rooms']
@[node]
struct MRoom {
	id        int
	name      string
	room_type string @[col: 'type']
}

@[table: 'memberships']
@[node]
struct MMembership {
	id          int
	room_id     int
	user_id     int
	involvement string
	unread_at   string
}

@[edge]
fn (m MMembership) room() []MRoom {
	return []MRoom{}
}

@[table: 'messages']
@[node]
struct MMessage {
	id                int
	room_id           int
	creator_id        int
	client_message_id string
	created_at        string
}

@[table: 'action_text_rich_texts']
@[alias: 'rich']
@[node]
struct MRich {
	id          int
	record_id   int
	name        string
	record_type string
	body        string
}

@[table: 'message_mentions']
@[alias: 'mm']
@[node]
struct MMention {
	message_id int
	user_id    int
}

@[edge]
fn (m MMention) user() []MUser {
	return []MUser{}
}

fn mseed() !sqlite.DB {
	mut db := sqlite.connect(':memory:')!
	db.exec('create table users (id integer primary key, name text)')!
	db.exec("insert into users (id, name) values (7, 'amy')")!
	db.exec("insert into users (id, name) values (8, 'bo')")!
	db.exec('create table rooms (id integer primary key, name text, type text)')!
	db.exec("insert into rooms (id, name, type) values (3, 'Eng', 'Rooms::Open')")!
	db.exec("insert into rooms (id, name, type) values (4, 'Zebra', 'Rooms::Closed')")!
	db.exec('create table memberships (id integer primary key, room_id integer, user_id integer, involvement text, unread_at text)')!
	db.exec("insert into memberships (id, room_id, user_id, involvement, unread_at) values (1, 3, 7, 'mentions', '0')")!
	db.exec("insert into memberships (id, room_id, user_id, involvement, unread_at) values (2, 4, 7, 'everything', '2024-05-01 09:00:00.000000')")!
	db.exec("insert into memberships (id, room_id, user_id, involvement, unread_at) values (3, 3, 8, 'invisible', '0')")!
	db.exec('create table messages (id integer primary key, room_id integer, creator_id integer, client_message_id text, created_at text)')!
	db.exec("insert into messages (id, room_id, creator_id, client_message_id, created_at) values (11, 3, 7, 'c-11', '2024-05-01 10:00:00.000000')")!
	db.exec("insert into messages (id, room_id, creator_id, client_message_id, created_at) values (12, 3, 8, 'c-12', '2024-05-01 10:01:00.000000')")!
	db.exec('create table action_text_rich_texts (id integer primary key, record_type text, record_id integer, name text, body text)')!
	db.exec("insert into action_text_rich_texts (id, record_type, record_id, name, body) values (21, 'Message', 11, 'body', 'hello')")!
	db.exec("insert into action_text_rich_texts (id, record_type, record_id, name, body) values (22, 'Message', 12, 'body', 'hi')")!
	db.exec('create table message_mentions (id integer primary key, message_id integer, user_id integer)')!
	db.exec('insert into message_mentions (id, message_id, user_id) values (31, 11, 8)')!
	return db
}

fn mall(db &sqlite.DB, table string) ![]Row {
	return rows_of(db.exec('select * from ' + table)!)
}

fn rows_equal(a []Row, b []Row) bool {
	if a.len != b.len {
		return false
	}
	for i in 0 .. a.len {
		if a[i].len != b[i].len {
			return false
		}
		for k, v in a[i] {
			if b[i][k] != v {
				return false
			}
		}
	}
	return true
}

fn test_mem_filter_take_project() {
	leaf := [
		Row({
			'id':      '1'
			'room_id': '3'
			'user_id': '7'
		}),
		Row({
			'id':      '2'
			'room_id': '4'
			'user_id': '7'
		}),
	]
	got := new_query[MMembership]().where(pred('membership.room_id == param("rid") and membership.user_id == param("uid")')).take(1).project([
		'membership.id',
	]).bind({
		'rid': 3
		'uid': 7
	}).materialize(leaf, {})!
	assert got.len == 1
	assert got[0]['id'] == '1'
}

fn test_mem_in_list() {
	leaf := [
		Row({
			'id':   '7'
			'name': 'amy'
		}),
		Row({
			'id':   '8'
			'name': 'bo'
		}),
	]
	got := new_query[MUser]().where(pred('user.id in [7]')).project([
		'user.id',
		'user.name',
	]).materialize(leaf, {})!
	assert got.len == 1
	assert got[0]['name'] == 'amy'
}

fn test_member_agrees_with_sql() {
	mut db := mseed()!
	leaf := mall(&db, 'memberships')!
	q := new_query[MMembership]().where(pred('membership.room_id == param("rid") and membership.user_id == param("uid")')).take(1).project([
		'membership.id',
	]).bind({
		'rid': 3
		'uid': 7
	})
	assert rows_equal(q.materialize(leaf, {})!, q.rows_on(&db)!)
	nope := new_query[MMembership]().where(pred('membership.room_id == param("rid") and membership.user_id == param("uid")')).take(1).project([
		'membership.id',
	]).bind({
		'rid': 4
		'uid': 8
	})
	assert rows_equal(nope.materialize(leaf, {})!, nope.rows_on(&db)!)
}

fn test_sidebar_agrees_with_sql() {
	mut db := mseed()!
	leaf := mall(&db, 'memberships')!
	tables := {
		'room': mall(&db, 'rooms')!
	}
	q := new_query[MMembership]().where(pred('membership.user_id == param("uid") and membership.involvement != param("inv")')).edge(edge_to[MMembership, MRoom]('room',
		join_on('room_id', 'id'))).order_by(order('lower(room.name), room.id')).project([
		'membership.involvement',
		'membership.unread_at',
		'room.id',
		'room.name',
		'room.type',
	]).bind({
		'uid': 7
		'inv': 'invisible'
	})
	sql_rows := q.rows_on(&db)!
	mem_rows := q.materialize(leaf, tables)!
	assert rows_equal(mem_rows, sql_rows)
	assert mem_rows.len == 2
	assert mem_rows[0]['name'] == 'Eng'
	assert mem_rows[1]['name'] == 'Zebra'
}

fn test_mention_edge_where_after_join() {
	mut db := mseed()!
	leaf := mall(&db, 'message_mentions')!
	tables := {
		'user': mall(&db, 'users')!
	}
	q := new_query[MMention]().edge(edge_to[MMention, MUser]('user', join_on('user_id', 'id'))).where(pred('mm.message_id in [11]')).project([
		'mm.message_id',
		'user.name',
	])
	assert rows_equal(q.materialize(leaf, tables)!, q.rows_on(&db)!)
}

fn test_rich_bodies_agree_with_sql() {
	mut db := mseed()!
	leaf := mall(&db, 'action_text_rich_texts')!
	q := new_query[MRich]().where(pred('rich.record_id in [11,12] and rich.name == param("n") and rich.record_type in ["Message", "ActionText::RichText"]')).order_by(order('rich.id')).project([
		'rich.record_id',
		'rich.body',
	]).bind({
		'n': 'body'
	})
	assert rows_equal(q.materialize(leaf, {})!, q.rows_on(&db)!)
}

fn test_count_agrees_with_sql() {
	mut db := mseed()!
	leaf := mall(&db, 'messages')!
	q := new_query[MMessage]().where(pred('message.room_id == param("rid")')).count().bind({
		'rid': 3
	})
	assert rows_equal(q.materialize(leaf, {})!, q.rows_on(&db)!)
	assert count_value(q.materialize(leaf, {})!) == 2
}

fn test_desc_page_agrees_with_sql() {
	mut db := mseed()!
	leaf := mall(&db, 'messages')!
	q := new_query[MMessage]().where(pred('message.room_id == param("rid")')).order_by(order('desc(message.created_at), desc(message.id)')).take(40).project([
		'message.id',
	]).bind({
		'rid': 3
	})
	sql_rows := q.rows_on(&db)!
	mem_rows := q.materialize(leaf, {})!
	assert rows_equal(mem_rows, sql_rows)
	assert mem_rows[0]['id'] == '12'
	assert mem_rows[1]['id'] == '11'
}

fn test_like_lower() {
	leaf := [
		Row({
			'id':   '3'
			'name': 'Eng'
		}),
		Row({
			'id':   '4'
			'name': 'Zebra'
		}),
	]
	got := new_query[MRoom]().where(pred('like(lower(room.name), param("q"))')).project([
		'room.id',
	]).bind({
		'q': '%eng%'
	}).materialize(leaf, {})!
	assert got.len == 1
	assert got[0]['id'] == '3'
}

fn test_like_agrees_with_sql() {
	mut db := mseed()!
	leaf := mall(&db, 'rooms')!
	q := new_query[MRoom]().where(pred('like(lower(room.name), param("q"))')).project([
		'room.id',
	]).bind({
		'q': '%e%'
	})
	assert rows_equal(q.materialize(leaf, {})!, q.rows_on(&db)!)
}

fn test_match_is_substring() {
	rooms := [
		Row({
			'id':   '3'
			'name': 'deploy on friday afternoon'
		}),
		Row({
			'id':   '4'
			'name': 'lunch plans'
		}),
	]
	got := new_query[MRoom]().where(pred('match(room.name, param("q"))')).project([
		'room.id',
	]).bind({
		'q': 'FRIDAY'
	}).materialize(rooms, {})!
	assert got.len == 1
	assert got[0]['id'] == '3'
}

fn test_skip_take() {
	leaf := [
		Row({
			'id': '1'
		}),
		Row({
			'id': '2'
		}),
		Row({
			'id': '3'
		}),
	]
	q := new_query[MUser]()
	assert q.skip(1).take(1).project(['user.id']).materialize(leaf, {})![0]['id'] == '2'
	assert q.skip(9).project(['user.id']).materialize(leaf, {})!.len == 0
	assert q.take(0).project(['user.id']).materialize(leaf, {})!.len == 0
}

fn test_is_null() {
	leaf := [
		Row({
			'id':        '1'
			'unread_at': '0'
		}),
		Row({
			'id': '2'
		}),
	]
	q := new_query[MMembership]()
	assert q.where(pred('membership.unread_at is null')).project(['membership.id']).materialize(leaf,
		{})!.len == 1
	assert q.where(pred('membership.unread_at is not null')).project(['membership.id']).materialize(leaf,
		{})!.len == 1
}

fn test_page_window_or() {
	leaf := [
		Row({
			'id':         '11'
			'created_at': '2024-05-01 10:00:00.000000'
		}),
		Row({
			'id':         '12'
			'created_at': '2024-05-01 10:01:00.000000'
		}),
	]
	got := new_query[MMessage]().where(pred('message.created_at > param("ts") or (message.created_at == param("ts") and message.id > param("mid"))')).project([
		'message.id',
	]).bind({
		'ts':  '2024-05-01 10:00:00.000000'
		'mid': 11
	}).materialize(leaf, {})!
	assert got.len == 1
	assert got[0]['id'] == '12'
}

fn test_project_as() {
	leaf := [
		Row({
			'id':   '3'
			'name': 'Eng'
		}),
	]
	got := new_query[MRoom]().project(['room.id AS rid', 'room.name']).materialize(leaf, {})!
	assert got[0]['rid'] == '3'
	assert got[0]['name'] == 'Eng'
	assert 'id' !in got[0]
}

fn test_missing_param_materialize() {
	leaf := [
		Row({
			'id': '1'
		}),
	]
	q := new_query[MUser]().where(pred('user.id == param("id")')).project(['user.id'])
	if _ := q.materialize(leaf, {}) {
		assert false, 'expected a missing-param error'
	} else {
		assert err.msg().contains('id')
	}
}

fn test_missing_edge_table() {
	leaf := [
		Row({
			'id':      '1'
			'room_id': '3'
		}),
	]
	q := new_query[MMembership]().edge(edge_to[MMembership, MRoom]('room', join_on('room_id', 'id'))).project([
		'membership.id',
	])
	if _ := q.materialize(leaf, {}) {
		assert false, 'expected a missing-tables error'
	} else {
		assert err.msg().contains('room')
	}
}

fn test_unknown_column_materialize() {
	leaf := [
		Row({
			'id': '1'
		}),
	]
	q := new_query[MUser]().where(pred('user.nope == 1')).project(['user.id'])
	if _ := q.materialize(leaf, {}) {
		assert false, 'expected an unknown-column error'
	} else {
		assert err.msg().contains('user.nope')
	}
}

// Edge accessors resolve at method-call time against a TableStore (the
// materialize_walk_obj half: live objects, nothing precomputed).
// Transpiler-emitted alongside the @[edge] stubs: filter target rows on
// the JoinOn keys, decode.
fn (m MMembership) room_objs(s TableStore) ![]MRoom {
	return decode_all[MRoom](s.lookup('room', 'id', m.room_id.str())!)
}

fn (m MMention) user_objs(s TableStore) ![]MUser {
	return decode_all[MUser](s.lookup('user', 'id', m.user_id.str())!)
}

fn mstore(db &sqlite.DB) !TableStore {
	mut s := new_table_store()
	s.put('room', mall(db, 'rooms')!)
	s.put('user', mall(db, 'users')!)
	s.put('membership', mall(db, 'memberships')!)
	return s
}

fn test_obj_edges_resolve_at_call_time() {
	mut db := mseed()!
	s := mstore(&db)!
	members := decode_all[MMembership](s.rows('membership')!)
	assert members.len == 3
	// Nothing resolved until the accessor runs: room of membership 1.
	rooms := members[0].room_objs(s)!
	assert rooms.len == 1
	assert rooms[0].name == 'Eng'
	assert rooms[0].room_type == 'Rooms::Open'
	// Join miss resolves to empty, like the SQL INNER JOIN.
	non := MMembership{
		room_id: 99
	}
	assert non.room_objs(s)!.len == 0
	// Mention edge across tables.
	men := decode_all[MMention](rows_of(db.exec('select * from message_mentions')!))
	assert men[0].user_objs(s)![0].name == 'bo'
}

fn test_obj_unknown_alias_errors() {
	s := new_table_store()
	if _ := s.rows('room') {
		assert false, 'expected an unknown-alias error'
	} else {
		assert err.msg().contains('room')
	}
}
