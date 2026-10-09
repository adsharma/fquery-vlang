# fquery-vlang

fquery-style declarative queries for V: map structs to SQL records with
attributes, build queries with method chains, run them on sqlite. A V
port of `src/campfile/fq.py` (and the `fquery` engine bits it relies on)
from `../once-campfire-python`, built as the query layer for a V version
of the same app produced by a transpiler.

```v
import db.sqlite
import fquery
import campfile

mut db := sqlite.connect('campfile.db')!
rows := campfile.new_membership_query().
	where(fquery.pred('membership.room_id == param("rid") and membership.user_id == param("uid")')).
	take(1).project(['membership.id']).
	bind({'rid': room_id, 'uid': user_id}).
	rows_on(&db)!
```

Every literal becomes a `?` placeholder; user input travels only via
`param("name")` + `bind()`, never as SQL text — the same guarantee as the
Python side. Writes stay on raw SQL; PK lookups stay direct.

## Layout

| Path | Purpose |
|---|---|
| `fquery/fquery.v` | `Query[T]`, chain methods, SQL renderer, `use_db`/ambient `rows()` |
| `fquery/parser.v` | Predicate + order-key language (port of `sql_builder`'s compiler) |
| `fquery/columns.v` | Field → column mapping via `@[col]` (comptime `f.attrs`) |
| `fquery/decode.v` | Typed row decoding via comptime fields (`decode_row`/`decode_all`) |
| `fquery/globals.v` | Ambient connection (mirrors `fquery.env.use`) |
| `fquery/materialize.v` | In-memory backend: `materialize()` fold over `ops` |
| `fquery/materialize_test.v` | In-memory semantics + SQL/materialize agreement tests |
| `fquery/fquery_test.v` | SQL-string parity + live round-trips (the transpiler contract) |
| `examples/campfile/fq.v` | Node structs + constructors (port of `fq.py`) |
| `examples/campfile/queries.v` | Hot-path reads (port of `queries.py`) |
| `examples/campfile/campfile_test.v` | End-to-end against a Rails-shaped DB |

## Declarations: Python → V

| Python (`fq.py`) | V (`examples/campfile/fq.v`) |
|---|---|
| `@node @dataclass class UserNode` | `@[node] struct User` (node types are named for the entity; `@[node]` is required) |
| `make_query_type(N, "UserQuery", {"TABLE": "users"})` | `@[table: 'users']` on the struct + `new_user_query()` |
| `{"TABLE": t, "ALIAS": a}` | `@[table: 't'; alias: 'a']` (alias defaults to the singular stem, as in `alias_for`) |
| field → same-named column | same, unless overridden |
| reserved-word column (`rooms.type`) | `room_type string @[col: 'type']` (`type` is a V keyword) |
| `@edge async def room(...) -> List[RoomNode]` | a stub, like the Python body: declares name → target type, never runs |

Table/alias come from struct attributes read at compile time (`$for attr
in T.attributes`); the field list seeds a per-alias known-column registry,
so every `project`/`where`/`order_by` reference is validated before it
reaches sqlite (unknown alias/column is a chain error, not a sqlite error).
Edge steps resolve through the declared `@[edge]` stubs: `edge_to`
checks the name → target mapping at compile time, the
`EDGE_NAME_TO_RETURN_TYPE` equivalent (see rule 2 below for why it is a free fn).

## Chains: Python → V

| Python | V |
|---|---|
| `UserQuery([])` | `new_user_query()` (or `fquery.new_query[User]()`) |
| `fq.pred('...')` / `fq.order('...')` | `fquery.pred('...')` / `fquery.order('...')` (strings pass through as-is) |
| `.where(...)` / `.order_by(...)` / `.take(n)` / `.skip(n)` / `.project([...])` / `.count()` | same |
| `.edge("room", JoinOn("room_id", "id"))` | `.edge(fquery.edge_to[Membership, Room]('room', fquery.join_on('room_id', 'id')))` — leaf + target from the chain and the `@edge` annotation; validated against the `@[edge]` stubs |
| `.bind(**({"rid": rid}))` | `.bind({'rid': rid})` — ints/strings/bools wrap into `Pval` automatically |
| `fq.use_db(session)` + `.rows()` | `fquery.use_db(db)` + `.rows()` (ambient), or `.rows_on(&db)` (explicit) |
| `total[0]["COUNT(*)"]` | `fquery.count_value(rows)` |
| list-of-dict rows | `[]fquery.Row` (`map[string]string`, bare column keys, same as Python) |
| hand-decoded views | `decode_all[Entry](rows)`, or `.rows_as_on(&db)` when leaf type == row type |

Builder methods never fail: the first error sticks and surfaces from the
terminal `to_sql()` / `rows_on()` / `rows()` calls (`!`), so chains stay
one `!` at the end.

Predicate language (same strings as Python): `== != < <= > >=`,
`== None` / `is [not] null`, `[not] in [...]`, `and`/`or`/parens,
`like(col, pat)`, `like(lower(col), pat)`, `match(col, param("q"))`,
`lower(col)`, `desc(col)` + comma-separated multi-key order.

## Compile-time design

- **Monomorphized query types.** `Query[User]` is a distinct compile-time
  type carrying its table/alias/columns — the equivalent of
  `make_query_type`, but resolved by the compiler, with zero runtime
  registry for edges (`EDGE_NAME_TO_RETURN_TYPE` has no V counterpart;
  the edge target is a type parameter).
- **Attribute-driven mapping.** `@[table]` / `@[alias]` (struct level,
  via `T.attributes`) and `@[col]` (field level, via `f.attrs`) are the
  single source of truth for validation (`check_field`) and decoding
  (`decode_row`) alike.
- **Typed decode without boilerplate.** `decode_row[U]` fills any struct
  from a row using `$for f in U.fields` + `$if f.typ is ...`; no per-entity
  row parsers to transpile.

## Backends: SQL, materialize_walk, materialize_walk_obj

Like fquery, the chain is backend data, not SQL text. Each call appends
an `Op` (the `QueryableOp` equivalent: where/project/take/skip/count/
edge/order) in call order. Three consumers use it:

- `to_sql()` / `rows_on()` - the `SQLBuilderVisitor` equivalent.
- `materialize(leaf, tables)` - the `send()`/`materialize_walk`
  equivalent, folding eagerly over in-memory rows: where=filter (the shared
  `Crit` tree evaluated against rows), project=map keys, take/skip=slice,
  order=stable multi-key sort, edge=flat hash join on the `JoinOn` keys,
  count=len. `dump()` prints the op tree (the `.dump()`/`.debug()`
  equivalent).

```v
leaf := fquery.rows_of(db.exec('select * from memberships')!)
tables := {'room': fquery.rows_of(db.exec('select * from rooms')!)}
mem_rows := q.materialize(leaf, tables)! // same rows as q.rows_on(&db)!
```

The `materialize_walk_obj` half is live objects instead of an eager
snapshot: decode now (`decode_all`), resolve edges when their accessor
runs. `TableStore` is the row source (the `ViewModel` registry role);
per-edge accessor methods filter it on the `JoinOn` keys at call time, so
nothing is precomputed:

```v
store.put('room', fquery.rows_of(db.exec('select * from rooms')!))
rooms := membership.room_objs(store)! // resolved HERE, not before
```

The visited/unvisited distinction collapses: with no awaitables to force,
everything is strictly on-call, which is exactly "defers materialization
to method call time". The store is passed explicitly (V has no attribute
hooks or shared-graph GC to hide it behind). Python edges can run arbitrary
per-item code; `TableStore` edges are key lookups, which covers every edge
in the campfire app.

Deliberate deviations from Python's engine: edges flatten (V `Row`s can't
nest, and the app consumes flat join rows); `COUNT(*)` cells key as
`'COUNT(*)'` like the SQL backend (Python uses `'count'`); `match()` (FTS5)
degrades to case-insensitive substring; missing keys read as `''` and count
as NULL; `LIKE` is case-insensitive (sqlite default). V has no `ViewModel`
registry, so the caller supplies leaf + edge-target row sets.
`materialize_test.v` pins row-for-row SQL/materialize agreement on a seeded
DB. The `campfile` hot paths stay SQL-backed; both in-memory forms are there
for tests, offline use, and the transpiler's in-memory targets.

## V 0.5.2 rules (transpiler must obey these)

Found by probing; all are load-bearing for emitted code:

1. `pub` generic fns must mention every type param in args/return (the
   receiver doesn't count) — hence `rows_as_on[T]`, `columns_of[T]()`. 
2. A generic method's **own** type params are broken: `edge[U]` on
   `Query[T]` silently unifies `U` across call sites (wrong joins,
   wrong `U.name`). Methods whose params match the struct (`rows_as_on[T]`)
   are fine, as are multi-param **free** fns. So types travel through
   free fns (`edge_to[T, U]`, `new_query[T]`, `columns_of[T]`), and chain
   methods take no type params. A transpiler must never emit `fn (q
   Query[T]) m[U](...)` with `U != T`.
2. Generic methods with an explicit `[...]` list must be declared **in the
   same file as their struct**, or calls fail with `unknown method`
   (observed with `decode.v` → fixed by moving them into `fquery.v`).
3. Field attributes are visible via `f.attrs` (raw strings like
   `'col: type'`), **not** via `$for attr in f.attributes` (empty for
   fields). Only struct-level `T.attributes` parses name/arg.
4. `sql` is a reserved word (`BuiltSql.statement`, not `.sql`).
5. `__global` needs `-enable-globals` on every `v run`/`v test`.
6. Old `[attr]` syntax is rejected; use `@[attr]`.
7. `!=` renders as `<>` (matches Python's `_cmp_ops`, asserted in tests).

## Running

```sh
v -enable-globals test fquery examples/campfile
```

`fquery_test.v` pins the exact SQL + params for every chain shape used by
`queries.py`/`ops.py` — treat failures there as transpiler-contract
breaks. `campfile_test.v` runs the ported hot paths against an in-memory
Rails-shaped schema.

## Boundaries (same as Python)

- Reads are chains; writes are raw SQL (unported — same split as the app).
- `message_mentions` is the extension table; bodies live in
  `action_text_rich_texts`; FTS via `message_search_index`.
- All bind params travel as text; integer affinity makes numeric
  comparisons behave (verified live in `fquery_test.v`).
- One edge per chain is exercised (the app's max); joins always hang off
  the leaf alias, as in `SQLBuilderVisitor`.
