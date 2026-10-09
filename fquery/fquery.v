// fquery for V: declarative struct-to-SQL mapping + chained queries.
//
// A query type is derived at compile time from a node struct:
//
//   @[table: 'memberships']          // alias defaults to the singular stem
//   struct Membership { ... }        // -> table "memberships", alias "membership"
//
//   @[table: 'message_search_index'; alias: 'idx']
//   struct Fts { ... }
//
// Chains mirror the Python call sites one-to-one so a transpiler can map
// them mechanically:
//
//   q := new_query[Membership]()
//   rows := q.where(pred('membership.room_id == param("rid")')).
//       take(1).project(['membership.id']).
//       bind({'rid': rid})!.to_rows(&db)!
//
// Every literal becomes a `?` placeholder; bound params travel separately.
// Builder methods never fail: the first error sticks and surfaces from the
// terminal to_sql()/rows() calls.
module fquery

import db.sqlite

// Pval is a bindable param value. Everything is sent to sqlite as text;
// column affinity makes numeric comparisons behave (as in the Python app,
// where the sqlite3 driver binds ints and strings interchangeably here).
pub type Pval = bool | f64 | i64 | int | string

pub fn pval_str(v Pval) string {
	match v {
		bool {
			return if v { '1' } else { '0' }
		}
		int {
			return v.str()
		}
		i64 {
			return v.str()
		}
		f64 {
			return v.str()
		}
		string {
			return v
		}
	}
}

// Row is one result record, keyed by bare column name
// (project(['user.id']) -> row['id']), exactly like the Python dict rows.
// COUNT(*) queries key the count under 'COUNT(*)'.
pub type Row = map[string]string

// JoinOn names the SQL join keys: source.left_col = target.right_col.
pub struct JoinOn {
pub:
	left  string
	right string
}

pub fn join_on(left string, right string) JoinOn {
	return JoinOn{
		left:  left
		right: right
	}
}

// pred wraps a predicate string (transpiler target for fq.pred()).
pub fn pred(s string) string {
	return s
}

// order wraps an order-key string (transpiler target for fq.order()).
pub fn order(s string) string {
	return s
}

// Op is one link of the chain: the V equivalent of fquery's QueryableOp
// nodes (WhereQueryable, ProjectQueryable, TakeQueryable, ...). The chain
// is backend data, not SQL text. to_sql() is one fold over ops (the
// SQLBuilderVisitor equivalent); a future in-memory materialize_walk
// would be another fold over the same ops (where=filter, project=map,
// take/skip=slice, order=sort, edge=join, count=len). Op order is call
// order, exactly like the nested Python chain.
type Op = OpCount | OpEdge | OpOrder | OpProject | OpSkip | OpTake | OpWhere

struct OpWhere {
	raw string
}

struct OpOrder {
	raw string
}

struct OpProject {
	cols []string
}

struct OpTake {
	n int
}

struct OpSkip {
	n int
}

struct OpCount {}

struct OpEdge {
	edge_name    string
	left_alias   string
	left_col     string
	right_col    string
	target_table string
	target_alias string
}

// Query[T] is the V equivalent of a make_query_type class: the leaf table
// and alias are resolved at compile time from T's struct attributes, and
// T's field list seeds the known-column registry used to validate every
// project/where/order reference before it reaches sqlite.
pub struct Query[T] {
	table string
	alias string
mut:
	ops       []Op
	known     map[string][]string
	bindings  map[string]Pval
	build_err string
}

pub fn new_query[T]() Query[T] {
	mut table := ''
	mut alias := ''
	mut is_node := false
	$for attr in T.attributes {
		if attr.name == 'table' {
			table = attr.arg
		} else if attr.name == 'alias' {
			alias = attr.arg
		} else if attr.name == 'node' {
			is_node = true
		}
	}
	if !is_node {
		return Query[T]{
			build_err: 'fquery: struct ${T.name} is not a @[node] (nodes mirror fquery @node dataclasses)'
		}
	}
	if table == '' {
		return Query[T]{
			build_err: 'fquery: struct ${T.name} needs a [table: ...] attribute'
		}
	}
	if alias == '' {
		if table.ends_with('s') {
			alias = table[..table.len - 1]
		} else {
			alias = table
		}
	}
	mut known := map[string][]string{}
	known[alias] = columns_of[T]()
	return Query[T]{
		table: table
		alias: alias
		known: known
	}
}

fn (q Query[T]) fork() Query[T] {
	mut c := Query[T]{
		table:     q.table
		alias:     q.alias
		build_err: q.build_err
	}
	c.ops = q.ops.clone()
	c.known = q.known.clone()
	c.bindings = q.bindings.clone()
	return c
}

fn (q Query[T]) fail(msg string) Query[T] {
	mut c := q.fork()
	if c.build_err == '' {
		c.build_err = msg
	}
	return c
}

pub fn (q Query[T]) table_name() string {
	return q.table
}

pub fn (q Query[T]) table_alias() string {
	return q.alias
}

pub fn (q Query[T]) where(p string) Query[T] {
	if q.build_err != '' {
		return q
	}
	mut c := q.fork()
	c.ops << Op(OpWhere{
		raw: p
	})
	return c
}

pub fn (q Query[T]) order_by(o string) Query[T] {
	if q.build_err != '' {
		return q
	}
	mut c := q.fork()
	c.ops << Op(OpOrder{
		raw: o
	})
	return c
}

pub fn (q Query[T]) take(n int) Query[T] {
	if q.build_err != '' {
		return q
	}
	mut c := q.fork()
	c.ops << Op(OpTake{
		n: n
	})
	return c
}

pub fn (q Query[T]) skip(n int) Query[T] {
	if q.build_err != '' {
		return q
	}
	mut c := q.fork()
	c.ops << Op(OpSkip{
		n: n
	})
	return c
}

pub fn (q Query[T]) project(cols []string) Query[T] {
	if q.build_err != '' {
		return q
	}
	mut c := q.fork()
	c.ops << Op(OpProject{
		cols: cols.clone()
	})
	return c
}

pub fn (q Query[T]) count() Query[T] {
	if q.build_err != '' {
		return q
	}
	mut c := q.fork()
	c.ops << Op(OpCount{})
	return c
}

// edge_names lists T's declared @[edge] names (for error messages).
fn edge_names[T]() []string {
	mut out := []string{}
	$for m in T.methods {
		if 'edge' in m.attrs {
			out << m.name
		}
	}
	return out
}

// EdgeSpec is a validated join step, built by edge_to and consumed by
// Query.edge. Fields stay private so specs can only come from edge_to,
// which binds edge name and target type at one site.
pub struct EdgeSpec {
	edge_name    string
	left_col     string
	right_col    string
	target_table string
	target_alias string
	target_cols  []string
	err          string
}

// edge_to validates an edge step: T must declare an @[edge] method named
// `name` targeting U (or []U) — the comptime equivalent of fquery's
// EDGE_NAME_TO_RETURN_TYPE. The transpiler fills T (leaf) and U from the
// chain and the @edge return annotation.
//
// NOTE(V 0.5.2): this is a free fn, not a method, on purpose. A generic
// method's own type params (edge[U] on Query[T]) silently unify across
// call sites, corrupting every instantiation but one. Free generic fns
// instantiate correctly, so the types travel here.
pub fn edge_to[T, U](name string, ctx JoinOn) EdgeSpec {
	ut := new_query[U]()
	if ut.build_err != '' {
		return EdgeSpec{
			err: ut.build_err
		}
	}
	mut found := false
	mut ok := false
	$for m in T.methods {
		if m.name == name && 'edge' in m.attrs {
			found = true
			$if m.return_type is U {
				ok = true
			} $else $if m.return_type is []U {
				ok = true
			}
		}
	}
	if !found {
		return EdgeSpec{
			err: 'fquery: node ${T.name} has no @[edge] `${name}` (declared: ${edge_names[T]()})'
		}
	}
	if !ok {
		return EdgeSpec{
			err: 'fquery: edge `${name}` on ${T.name} does not target ${U.name} (check the @[edge] return type)'
		}
	}
	return EdgeSpec{
		edge_name:    name
		left_col:     ctx.left
		right_col:    ctx.right
		target_table: ut.table
		target_alias: ut.alias
		target_cols:  ut.known[ut.alias].clone()
	}
}

// edge joins a validated spec into the chain. Like the Python builder,
// every join hangs off the leaf alias.
pub fn (q Query[T]) edge(spec EdgeSpec) Query[T] {
	if q.build_err != '' {
		return q
	}
	if spec.err != '' {
		return q.fail(spec.err)
	}
	mut c := q.fork()
	c.ops << Op(OpEdge{
		edge_name:    spec.edge_name
		left_alias:   q.alias
		left_col:     spec.left_col
		right_col:    spec.right_col
		target_table: spec.target_table
		target_alias: spec.target_alias
	})
	c.known[spec.target_alias] = spec.target_cols.clone()
	return c
}

pub fn (q Query[T]) bind(params map[string]Pval) Query[T] {
	if q.build_err != '' {
		return q
	}
	mut c := q.fork()
	for k, v in params {
		c.bindings[k] = v
	}
	return c
}

// BuiltSql is the compiled chain: statement with `?` placeholders + params.
pub struct BuiltSql {
pub:
	statement string
	params    []string
}

fn quote_ident(s string) string {
	return '"' + s.replace('"', '""') + '"'
}

fn render_field(alias string, col string, func string) string {
	ref := quote_ident(alias) + '.' + quote_ident(col)
	if func == 'lower' {
		return 'LOWER(' + ref + ')'
	}
	return ref
}

fn check_field(alias string, col string, known map[string][]string) ! {
	cols := known[alias] or {
		return error('fquery: unknown table alias `${alias}` (known: ${known.keys()})')
	}
	if col !in cols {
		return error('fquery: unknown column `${alias}.${col}` (known: ${cols})')
	}
}

fn resolve_val(v Val, bindings map[string]Pval, mut params []string) ! {
	match v {
		Lit {
			params << v.text
		}
		ParamRef {
			b := bindings[v.name] or { return error('fquery: missing bound param `${v.name}`') }
			params << pval_str(b)
		}
	}
}

fn render_crit(c Crit, known map[string][]string, bindings map[string]Pval, mut params []string) !string {
	match c {
		CritCmp {
			check_field(c.alias, c.col, known)!
			resolve_val(c.val, bindings, mut params)!
			return render_field(c.alias, c.col, '') + c.op + '?'
		}
		CritIsNull {
			check_field(c.alias, c.col, known)!
			if c.is_null {
				return render_field(c.alias, c.col, '') + ' IS NULL'
			}
			return render_field(c.alias, c.col, '') + ' IS NOT NULL'
		}
		CritIn {
			check_field(c.alias, c.col, known)!
			if c.vals.len == 0 {
				if c.negate {
					return '1=1'
				}
				return '1=0'
			}
			mut marks := []string{}
			for v in c.vals {
				resolve_val(v, bindings, mut params)!
				marks << '?'
			}
			out := render_field(c.alias, c.col, '') + ' IN (' + marks.join(',') + ')'
			if c.negate {
				return 'NOT ' + out
			}
			return out
		}
		CritLike {
			check_field(c.alias, c.col, known)!
			resolve_val(c.pat, bindings, mut params)!
			return render_field(c.alias, c.col, c.func) + ' LIKE ?'
		}
		CritMatch {
			check_field(c.alias, c.col, known)!
			resolve_val(c.q, bindings, mut params)!
			return render_field(c.alias, c.col, '') + ' MATCH ?'
		}
		CritAnd {
			mut parts := []string{}
			for p in c.parts {
				parts << render_crit(p, known, bindings, mut params)!
			}
			return '(' + parts.join(' AND ') + ')'
		}
		CritOr {
			mut parts := []string{}
			for p in c.parts {
				parts << render_crit(p, known, bindings, mut params)!
			}
			return '(' + parts.join(' OR ') + ')'
		}
	}
}

fn split_project(s string) (string, string) {
	upper := s.to_upper()
	idx := upper.last_index(' AS ') or { return s, '' }
	name := s[..idx].trim_space()
	out := s[idx + 4..].trim_space()
	return name, out
}

fn render_project(item string, known map[string][]string) !string {
	name, out := split_project(item)
	if name == ':id' {
		if out != '' {
			return quote_ident('id') + ' AS ' + quote_ident(out)
		}
		return quote_ident('id')
	}
	if name.contains('.') {
		parts := name.split('.')
		if parts.len != 2 {
			return error('fquery: bad project `${item}` (want alias.col)')
		}
		al := parts[0].trim_space()
		co := parts[1].trim_space()
		check_field(al, co, known)!
		rendered := render_field(al, co, '')
		if out != '' {
			return rendered + ' AS ' + quote_ident(out)
		}
		return rendered
	}
	return quote_ident(name)
}

// dump prints the chain in call order (the .dump()/.debug() equivalent),
// for transpiler debugging without touching sqlite.
pub fn (q Query[T]) dump() string {
	mut lines := ['LEAF ${q.table} AS ${q.alias}']
	for op in q.ops {
		match op {
			OpWhere {
				lines << 'WHERE ${op.raw}'
			}
			OpOrder {
				lines << 'ORDER_BY ${op.raw}'
			}
			OpProject {
				lines << 'PROJECT ${op.cols.join(', ')}'
			}
			OpTake {
				lines << 'TAKE ${op.n}'
			}
			OpSkip {
				lines << 'SKIP ${op.n}'
			}
			OpCount {
				lines << 'COUNT'
			}
			OpEdge {
				lines << 'EDGE ${op.edge_name} ON ${op.left_alias}.${op.left_col}=${op.target_alias}.${op.right_col}'
			}
		}
	}
	if q.build_err != '' {
		lines << 'ERROR ${q.build_err}'
	}
	return lines.join('\n')
}

pub fn (q Query[T]) to_sql() !BuiltSql {
	if q.build_err != '' {
		return error(q.build_err)
	}
	// Fold ops in call order (one pass; a future materialize_walk folds
	// the same ops with in-memory semantics instead of rendering SQL).
	mut cols := []string{}
	mut joins := []OpEdge{}
	mut crits := []Crit{}
	mut keys := []OrderKey{}
	mut take_n := -1
	mut skip_n := -1
	mut do_count := false
	for op in q.ops {
		match op {
			OpWhere {
				crits << parse_predicate(op.raw)!
			}
			OpOrder {
				keys << parse_order(op.raw)!
			}
			OpProject {
				for item in op.cols {
					cols << render_project(item, q.known)!
				}
			}
			OpTake {
				take_n = op.n
			}
			OpSkip {
				skip_n = op.n
			}
			OpCount {
				do_count = true
			}
			OpEdge {
				joins << op
			}
		}
	}
	if do_count {
		cols << 'COUNT(*)'
	}
	mut statement := 'SELECT ' + (if cols.len > 0 { cols.join(', ') } else { '*' })
	statement += ' FROM ' + quote_ident(q.table) + ' ' + quote_ident(q.alias)
	for j in joins {
		statement += ' JOIN ' + quote_ident(j.target_table) + ' ' + quote_ident(j.target_alias)
		statement += ' ON ' + quote_ident(j.left_alias) + '.' + quote_ident(j.left_col) + '='
		statement += quote_ident(j.target_alias) + '.' + quote_ident(j.right_col)
	}
	mut params := []string{}
	if crits.len > 0 {
		mut parts := []string{}
		for c in crits {
			parts << render_crit(c, q.known, q.bindings, mut params)!
		}
		combined := if parts.len == 1 { parts[0] } else { '(' + parts.join(' AND ') + ')' }
		// A single AND/OR criterion already carries its own parens.
		statement += ' WHERE ' + combined
	}
	if keys.len > 0 {
		mut parts := []string{}
		for k in keys {
			check_field(k.alias, k.col, q.known)!
			mut part := render_field(k.alias, k.col, k.func)
			if k.desc {
				part += ' DESC'
			}
			parts << part
		}
		statement += ' ORDER BY ' + parts.join(',')
	}
	if take_n >= 0 {
		statement += ' LIMIT ${take_n}'
	}
	if skip_n >= 0 {
		statement += ' OFFSET ${skip_n}'
	}
	return BuiltSql{
		statement: statement
		params:    params
	}
}

pub fn (q Query[T]) to_sql_string() !string {
	return q.to_sql()!.statement
}

// to_rows runs the chain on an explicit connection.
pub fn (q Query[T]) to_rows(db &sqlite.DB) ![]Row {
	built := q.to_sql()!
	return rows_of(db.exec_param_many(built.statement, built.params)!)
}

// Ambient connection, mirroring fquery.env.use(conn): set once per entry
// point (or per test), then chains read naturally as bind(...).rows().
// rows runs the chain on the ambient connection (see use_db).
pub fn (q Query[T]) rows() ![]Row {
	return q.to_rows(ambient_db()!)
}

// to_structs runs the chain and decodes each row into the leaf type T.
// (Generic methods with an explicit [...] list must live in the same file
// as their struct in V 0.5.2, hence these live here and not in decode.v.)
pub fn (q Query[T]) to_structs[T](db &sqlite.DB) ![]T {
	return decode_all[T](q.to_rows(db)!)
}

// rows_as runs on the ambient connection and decodes into the leaf type.
pub fn (q Query[T]) rows_as[T]() ![]T {
	return decode_all[T](q.rows()!)
}
