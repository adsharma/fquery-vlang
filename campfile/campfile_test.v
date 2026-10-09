// End-to-end: ported hot paths against a Rails-shaped sqlite DB.
module campfile

import db.sqlite

fn seed_db() !sqlite.DB {
	mut db := sqlite.connect(':memory:')!
	db.exec('create table users (id integer primary key, name text, email_address text, password_digest text, bio text, role integer, status integer)')!
	db.exec("insert into users (id, name, email_address, password_digest, bio, role, status) values (7, 'amy', 'amy@example.com', 'digest-7', '', 0, 0)")!
	db.exec("insert into users (id, name, email_address, password_digest, bio, role, status) values (8, 'bo', 'bo@example.com', 'digest-8', '', 0, 0)")!
	db.exec('create table rooms (id integer primary key, name text, type text, creator_id integer)')!
	db.exec("insert into rooms (id, name, type, creator_id) values (3, 'Eng', 'Rooms::Open', 7)")!
	db.exec("insert into rooms (id, name, type, creator_id) values (4, 'Zebra', 'Rooms::Closed', 7)")!
	db.exec('create table memberships (id integer primary key, room_id integer, user_id integer, involvement text, connections integer, connected_at text, unread_at text)')!
	db.exec("insert into memberships (id, room_id, user_id, involvement, unread_at) values (1, 3, 7, 'mentions', '0')")!
	db.exec("insert into memberships (id, room_id, user_id, involvement, unread_at) values (2, 4, 7, 'everything', '2024-05-01 09:00:00.000000')")!
	db.exec("insert into memberships (id, room_id, user_id, involvement, unread_at) values (3, 3, 8, 'invisible', '0')")!
	db.exec('create table messages (id integer primary key, room_id integer, creator_id integer, client_message_id text, created_at text)')!
	db.exec("insert into messages (id, room_id, creator_id, client_message_id, created_at) values (11, 3, 7, 'c-11', '2024-05-01 10:00:00.000000')")!
	db.exec("insert into messages (id, room_id, creator_id, client_message_id, created_at) values (12, 3, 8, 'c-12', '2024-05-01 10:01:00.000000')")!
	db.exec('create table action_text_rich_texts (id integer primary key, record_type text, record_id integer, name text, body text)')!
	db.exec("insert into action_text_rich_texts (id, record_type, record_id, name, body) values (21, 'Message', 11, 'body', 'hello @bo')")!
	db.exec("insert into action_text_rich_texts (id, record_type, record_id, name, body) values (22, 'Message', 12, 'body', 'hi @amy')")!
	db.exec('create table message_mentions (id integer primary key, message_id integer, user_id integer)')!
	db.exec('insert into message_mentions (id, message_id, user_id) values (31, 11, 8)')!
	db.exec('insert into message_mentions (id, message_id, user_id) values (32, 12, 7)')!
	db.exec('create table boosts (id integer primary key, message_id integer, booster_id integer, content text)')!
	db.exec("insert into boosts (id, message_id, booster_id, content) values (41, 11, 8, ':+1:')")!
	db.exec('create table sessions (id integer primary key, user_id integer, token text, last_active_at text)')!
	db.exec("insert into sessions (id, user_id, token, last_active_at) values (51, 7, 'tok-amy', '2024-05-01 09:59:00.000000')")!
	return db
}

fn test_is_member() {
	mut db := seed_db()!
	assert is_member(&db, 3, 7)
	assert !is_member(&db, 4, 8)
	assert !is_member(&db, 3, 99)
}

fn test_users_by_id() {
	mut db := seed_db()!
	names := users_by_id(&db, [7, 8])
	assert names[7] == 'amy'
	assert names[8] == 'bo'
	assert users_by_id(&db, []).len == 0
}

fn test_boosts_by_message() {
	mut db := seed_db()!
	boosts := boosts_by_message(&db, [11, 12])
	assert boosts[11] == [':+1:']
	assert boosts[12] == []string{}
}

fn test_mentions_by_message() {
	mut db := seed_db()!
	mentions := mentions_by_message(&db, [11, 12])
	assert mentions[11] == ['bo']
	assert mentions[12] == ['amy']
}

fn test_bodies_by_message() {
	mut db := seed_db()!
	bodies := bodies_by_message(&db, [11, 12])
	assert bodies[11] == 'hello @bo'
	assert bodies[12] == 'hi @amy'
}

fn test_sidebar() {
	mut db := seed_db()!
	entries := sidebar(&db, 7)!
	assert entries.len == 2
	assert entries[0].room_name == 'Eng'
	assert entries[0].room_kind == 0
	assert entries[0].unread == false
	assert entries[0].involvement == 2
	assert entries[1].room_name == 'Zebra'
	assert entries[1].room_kind == 1
	assert entries[1].unread == true
	// Invisible memberships are scoped out: bo sees nothing of room 3.
	assert sidebar(&db, 8)!.len == 0
}

fn test_room_messages_and_count() {
	mut db := seed_db()!
	msgs := room_messages(&db, 3)!
	assert msgs.len == 2
	assert msgs[0]['id'] == '12' // newest first (desc order)
	assert msgs[1]['id'] == '11'
	assert message_count(&db, 3)! == 2
	assert message_count(&db, 4)! == 0
}

fn test_user_by_email() {
	mut db := seed_db()!
	rows := user_by_email(&db, 'amy@example.com')!
	assert rows.len == 1
	assert rows[0]['name'] == 'amy'
	assert rows[0]['status'] == '0'
	assert user_by_email(&db, 'nobody@example.com')!.len == 0
}

fn test_session_by_token() {
	mut db := seed_db()!
	rows := session_by_token(&db, 'tok-amy')!
	assert rows.len == 1
	assert rows[0]['user_id'] == '7'
	assert session_by_token(&db, 'bogus')!.len == 0
}
