// Hot-path reads ported from src/campfile/queries.py.
//
// Each function mirrors its Python original chain-for-chain: same tables,
// same predicates, same projections. Writes stay on raw SQL (like the
// Python app); PK lookups stay direct. The mechanical transpiler rules are:
//
//   fq.XxxQuery([])            -> new_xxx_query()
//   .where(fq.pred('...'))     -> .where(fquery.pred('...'))      (string as-is)
//   .order_by(fq.order('...')) -> .order_by(fquery.order('...'))  (string as-is)
//   .edge("n", JoinOn(a, b))   -> .edge(fquery.edge_to[Leaf, Target]('n', fquery.join_on(a, b)))
//   .take(n)/.project([...])   -> same
//   .bind(**({...: ...}))      -> .bind({'...': ...})  (ints wrap into Pval)
//   .rows()                    -> .to_rows(db)! / .rows()!
module campfile

import db.sqlite
import fquery

pub const page_size = 40

// Rails STI type string -> domain kind int (mirrors ROOM_TYPE_TO_KIND).
const room_type_to_kind = {
	'Rooms::Open':   0
	'Rooms::Closed': 1
	'Rooms::Direct': 2
}

const involvement_to_id = {
	'invisible':  0
	'nothing':    1
	'mentions':   2
	'everything': 3
}

pub const msg_cols = [
	'message.id',
	'message.room_id',
	'message.creator_id',
	'message.client_message_id',
	'message.created_at',
]

fn int_list(ids []int) string {
	return ids.map(it.str()).join(',')
}

// is_member mirrors queries._member.
pub fn is_member(db &sqlite.DB, room_id int, user_id int) bool {
	rows := new_membership_query().where(fquery.pred('membership.room_id == param("rid") and membership.user_id == param("uid")')).take(1).project([
		'membership.id',
	]).bind({
		'rid': room_id
		'uid': user_id
	}).to_rows(db) or { return false }
	return rows.len > 0
}

// users_by_id mirrors queries._users_by_id.
pub fn users_by_id(db &sqlite.DB, ids []int) map[int]string {
	mut out := map[int]string{}
	if ids.len == 0 {
		return out
	}
	rows := new_user_query().where(fquery.pred('user.id in [${int_list(ids)}]')).project([
		'user.id',
		'user.name',
	]).to_rows(db) or { return out }
	for r in rows {
		out[r['id'].int()] = r['name']
	}
	return out
}

// boosts_by_message mirrors queries._boosts_by_message.
pub fn boosts_by_message(db &sqlite.DB, ids []int) map[int][]string {
	mut out := map[int][]string{}
	for id in ids {
		out[id] = []string{}
	}
	if ids.len == 0 {
		return out
	}
	rows := new_boost_query().where(fquery.pred('boost.message_id in [${int_list(ids)}]')).project([
		'boost.message_id',
		'boost.content',
	]).to_rows(db) or { return out }
	for r in rows {
		mid := r['message_id'].int()
		if mid in out {
			out[mid] << r['content']
		}
	}
	return out
}

// mentions_by_message mirrors queries._mentions_by_message.
pub fn mentions_by_message(db &sqlite.DB, ids []int) map[int][]string {
	mut out := map[int][]string{}
	for id in ids {
		out[id] = []string{}
	}
	if ids.len == 0 {
		return out
	}
	rows := new_message_mention_query().edge(fquery.edge_to[MessageMention, User]('user',
		fquery.join_on('user_id', 'id'))).where(fquery.pred('mm.message_id in [${int_list(ids)}]')).project([
		'mm.message_id',
		'user.name',
	]).to_rows(db) or { return out }
	for r in rows {
		mid := r['message_id'].int()
		if mid in out && r['name'] != '' {
			out[mid] << r['name']
		}
	}
	return out
}

// bodies_by_message mirrors queries._bodies_by_message.
pub fn bodies_by_message(db &sqlite.DB, ids []int) map[int]string {
	mut out := map[int]string{}
	if ids.len == 0 {
		return out
	}
	rows := new_rich_text_query().where(fquery.pred('rich.record_id in [${int_list(ids)}] and rich.name == param("n") and rich.record_type in ["Message", "ActionText::RichText"]')).order_by(fquery.order('rich.id')).project([
		'rich.record_id',
		'rich.body',
	]).bind({
		'n': 'body'
	}).to_rows(db) or { return out }
	for r in rows {
		out[r['record_id'].int()] = r['body']
	}
	return out
}

pub struct SidebarEntry {
pub mut:
	room_id     int
	room_name   string
	room_kind   int
	unread      bool
	involvement int
}

// sidebar mirrors queries.sidebar (membership scoping + room join).
pub fn sidebar(db &sqlite.DB, user_id int) ![]SidebarEntry {
	rows := new_membership_query().where(fquery.pred('membership.user_id == param("uid") and membership.involvement != param("inv")')).edge(fquery.edge_to[Membership, Room]('room',
		fquery.join_on('room_id', 'id'))).order_by(fquery.order('lower(room.name), room.id')).project([
		'membership.involvement',
		'membership.unread_at',
		'room.id',
		'room.name',
		'room.type',
	]).bind({
		'uid': user_id
		'inv': 'invisible'
	}).to_rows(db)!
	mut out := []SidebarEntry{cap: rows.len}
	for r in rows {
		// unread_at arrives as '' (NULL), '0', or ISO text.
		unread := r['unread_at'] != '' && r['unread_at'] != '0'
		out << SidebarEntry{
			room_id:     r['id'].int()
			room_name:   r['name']
			room_kind:   room_type_to_kind[r['type']] or { 1 }
			unread:      unread
			involvement: involvement_to_id[r['involvement']] or { 2 }
		}
	}
	return out
}

// room_messages mirrors the latest-page fetch in queries.room_page.
pub fn room_messages(db &sqlite.DB, room_id int) ![]fquery.Row {
	return new_message_query().where(fquery.pred('message.room_id == param("rid")')).order_by(fquery.order('desc(message.created_at), desc(message.id)')).take(page_size).project(msg_cols).bind({
		'rid': room_id
	}).to_rows(db)!
}

// message_count mirrors the has_more count in queries.room_page.
pub fn message_count(db &sqlite.DB, room_id int) !int {
	rows := new_message_query().where(fquery.pred('message.room_id == param("rid")')).count().bind({
		'rid': room_id
	}).to_rows(db)!
	return fquery.count_value(rows)
}

// user_by_email mirrors queries.authenticate (row lookup only; bcrypt
// verification stays outside the query layer, as in Python).
pub fn user_by_email(db &sqlite.DB, email string) ![]fquery.Row {
	return new_user_query().where(fquery.pred('user.email_address == param("email")')).take(1).project([
		'user.id',
		'user.name',
		'user.email_address',
		'user.password_digest',
		'user.role',
		'user.status',
		'user.bio',
	]).bind({
		'email': email
	}).to_rows(db)!
}

// user_from_token mirrors queries.user_from_token (session row lookup;
// the throttled touch + user fetch stay in plain code, as in Python).
pub fn session_by_token(db &sqlite.DB, token string) ![]fquery.Row {
	return new_user_session_query().where(fquery.pred('sess.token == param("tok")')).take(1).project([
		'sess.id',
		'sess.user_id',
		'sess.last_active_at',
	]).bind({
		'tok': token
	}).to_rows(db)!
}

// fts_search mirrors the FTS branch of queries.search_page.
pub fn fts_search(db &sqlite.DB, room_ids []int, q string, limit int) ![]fquery.Row {
	return new_fts_query().edge(fquery.edge_to[Fts, Message]('messages', fquery.join_on('rowid',
		'id'))).where(fquery.pred('match(idx.body, param("q")) and message.room_id in [${int_list(room_ids)}]')).order_by(fquery.order('message.created_at')).take(limit).project([
		'message.id',
		'message.room_id',
		'message.creator_id',
		'message.client_message_id',
		'message.created_at',
	]).bind({
		'q': q
	}).to_rows(db)!
}
