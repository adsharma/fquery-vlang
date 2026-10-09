# fquery-vlang

fquery-style declarative queries for V: declare nodes and edges with
attributes, chain queries off them, run on sqlite or in memory. A V port
of fquery's node/edge bindings plus its SQL and tree-walk engine bits,
built as the query layer for a V campfire app produced by a transpiler
(see `examples/campfile`).

## Nodes

```v
@[node; table: 'users']
struct User {
mut:
	id   int
	name string
	age  int
}

@[node; table: 'reviews']
struct Review {
mut:
	id        int
	business  string
	rating    int
	author_id int
}

// Edge stubs declare the graph (name → target type) and never run,
// exactly like fq.py's `yield []` bodies.
@[edge]
fn (u User) reviews() []Review {
	return []Review{}
}

@[edge]
fn (r Review) author() []User {
	return []User{}
}
```

`@[node]` marks queryable structs (`new_query` rejects the rest);
`@[table]`/`@[alias]` set the SQL mapping (alias defaults to the singular
stem); `@[col: '...']` renames a field's column.

## Queries

```v
import db.sqlite
import fquery

mut db := sqlite.connect(':memory:')!

// SQL backend. Predicates are strings; every literal becomes a `?`
// placeholder and user input travels only via param() + bind().
q := fquery.new_query[User]().
	where(fquery.pred('user.age >= param("n")')).
	order_by(fquery.order('user.name')).take(3).
	project(['user.id', 'user.name']).
	bind({'n': 16})
sql_rows := q.rows_on(&db)!

// Joins go through declared edges: edge_to binds leaf + target types and
// validates the name against the @[edge] stubs at compile time.
j := fquery.new_query[User]().
	edge(fquery.edge_to[User, Review]('reviews', fquery.join_on('id', 'author_id'))).
	where(fquery.pred('review.rating > param("r")')).
	project(['user.name', 'review.business']).
	bind({'r': 4})
sql_joined := j.rows_on(&db)!

// Same chains run in memory: fold over rows instead of rendering SQL.
mem_rows := q.to_dicts(user_rows, {})!
mem_joined := j.to_dicts(user_rows, {'review': review_rows})!
```

`rows()` uses an ambient connection (`use_db(db)` once, mirroring
`fquery.env`); `rows_as_on()` decodes straight into structs; `dump()`
prints the chain for debugging.

## Lazy materialization and query languages

`materialize()` is the eager snapshot (`materialize_walk`); the lazy half
(`materialize_walk_obj`) is decode-now, resolve-at-call-time — a
`TableStore` holds row sets and per-edge accessors filter it when invoked
(`membership.room_objs(store)!`), so nothing is precomputed and the
visited/unvisited distinction collapses to strictly on-call. On the
serialization side, `to_sql()` renders parameterized sqlite today, but the
chain itself holds no SQL — just ordered `Op`s plus the shared predicate
tree — so Cypher/Malloy-style targets are more folds over the same IR,
unimplemented. Python edges can run arbitrary per-item code while V edges
are key lookups, which covers the app's edges.

## Run

```sh
v -enable-globals test fquery examples/campfile
```
