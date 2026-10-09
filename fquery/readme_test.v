module fquery

import db.sqlite

@[node; table: 'users']
struct ReadmeUser {
mut:
	id   int
	name string
	age  int
}

@[node; table: 'reviews']
struct ReadmeReview {
mut:
	id        int
	business  string
	rating    int
	author_id int
}

@[edge]
fn (u ReadmeUser) reviews() []ReadmeReview {
	return []ReadmeReview{}
}

fn test_readme_example() {
	mut db := sqlite.connect(':memory:')!
	db.exec('create table users (id integer primary key, name text, age integer)')!
	db.exec("insert into users values (1, 'amy', 16)")!
	db.exec("insert into users values (2, 'bo', 20)")!
	db.exec('create table reviews (id integer primary key, business text, rating integer, author_id integer)')!
	db.exec("insert into reviews values (1, 'cafe', 5, 2)")!
	q := new_query[ReadmeUser]().where(pred('user.age >= param("n")')).order_by(order('user.name')).take(3).project([
		'user.id',
		'user.name',
	]).bind({
		'n': 16
	})
	sql_rows := q.to_rows(&db)!
	assert sql_rows.len == 2
	j := new_query[ReadmeUser]().edge(edge_to[ReadmeUser, ReadmeReview]('reviews',
		join_on('id', 'author_id'))).where(pred('review.rating > param("r")')).project([
		'user.name',
		'review.business',
	]).bind({
		'r': 4
	})
	sql_joined := j.to_rows(&db)!
	assert sql_joined.len == 1
	assert sql_joined[0]['business'] == 'cafe'
	user_rows := rows_of(db.exec('select * from users')!)
	mem_rows := q.to_dicts(user_rows, {})!
	assert mem_rows.len == 2
	mem_joined := j.to_dicts(user_rows, {
		'review': rows_of(db.exec('select * from reviews')!)
	})!
	assert mem_joined.len == 1
}
