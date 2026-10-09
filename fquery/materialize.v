// In-memory backend: fold a chain over rows already in memory.
//
// The V equivalent of fquery's send()/materialize_walk, minus the async
// generator machinery (V folds eagerly) and with one deliberate semantic
// difference: edges FLATTEN. Python's visit_edge nests child rows under the
// edge name (parent["room"] = [...]) because ViewModels can hold trees;
// V Rows are flat string maps, and the campfire app consumes flat SQL join
// rows, so OpEdge is a hash join on the JoinOn keys returning wide rows —
// row-for-row identical to what to_sql()/rows_on() returns for the same
// chain. Cross-backend agreement is asserted in materialize_test.v.
//
// Conventions (documented deviations from sqlite/Python where they differ):
//   - field refs resolve as `alias.col`, falling back to bare `col`
//     (sqlite rows carry bare keys; the alias is checked first).
//   - missing keys read as '' and count as NULL for IS NULL.
//   - comparisons are numeric-aware: both sides numeric → f64 compare,
//     else lexicographic string compare (mirrors sqlite affinity).
//   - LIKE is case-insensitive (sqlite's default).
//   - match() (FTS5) degrades to case-insensitive substring.
//   - COUNT(*) cells key as 'COUNT(*)', like the SQL backend (Python's
//     in-memory backend uses 'count').
//   - caller supplies leaf + edge-target rows; V has no ViewModel
//     registry to pull them from.
module fquery

import db.sqlite

// rows_of converts raw sqlite rows to Rows (bare column keys). rows_on is
// built on it; feed its output back in as materialize() input to compare
// backends on the same data.
pub fn rows_of(srows []sqlite.Row) []Row {
	mut out := []Row{cap: srows.len}
	for r in srows {
		mut m := map[string]string{}
		for i, name in r.names {
			m[name] = if i < r.vals.len { r.vals[i] } else { '' }
		}
		out << Row(m)
	}
	return out
}

fn field_val(row Row, alias string, col string) string {
	if alias != '' {
		qualified := alias + '.' + col
		if qualified in row {
			return row[qualified]
		}
	}
	if col in row {
		return row[col]
	}
	return ''
}

fn is_num(s string) bool {
	if s == '' {
		return false
	}
	mut i := 0
	if s[0] == `-` {
		i = 1
		if s.len == 1 {
			return false
		}
	}
	mut dot := false
	mut digits := 0
	for i < s.len {
		c := s[i]
		if c == `.` {
			if dot {
				return false
			}
			dot = true
		} else if c >= `0` && c <= `9` {
			digits++
		} else {
			return false
		}
		i++
	}
	return digits > 0
}

fn cmp_str(a string, b string) int {
	if is_num(a) && is_num(b) {
		fa := a.f64()
		fb := b.f64()
		if fa < fb {
			return -1
		} else if fa > fb {
			return 1
		}
		return 0
	}
	if a < b {
		return -1
	} else if a > b {
		return 1
	}
	return 0
}

fn resolve_crit_val(v Val, bindings map[string]Pval) !string {
	match v {
		Lit {
			return v.text
		}
		ParamRef {
			b := bindings[v.name] or { return error('fquery: missing bound param `${v.name}`') }
			return pval_str(b)
		}
	}
}

// like_match reports SQL LIKE (case-insensitive): % runs, _ single chars.
fn like_match(s string, pat string) bool {
	ls := s.to_lower()
	lp := pat.to_lower()
	mut si := 0
	mut pi := 0
	mut star := -1
	mut ss := 0
	for si < ls.len {
		if pi < lp.len && (lp[pi] == `_` || lp[pi] == ls[si]) {
			si++
			pi++
			continue
		}
		if pi < lp.len && lp[pi] == `%` {
			star = pi
			pi++
			ss = si
			continue
		}
		if star != -1 {
			pi = star + 1
			ss++
			si = ss
			continue
		}
		return false
	}
	for pi < lp.len && lp[pi] == `%` {
		pi++
	}
	return pi == lp.len
}

fn eval_crit(c Crit, row Row, bindings map[string]Pval) !bool {
	match c {
		CritCmp {
			l := field_val(row, c.alias, c.col)
			r := resolve_crit_val(c.val, bindings)!
			d := cmp_str(l, r)
			if c.op == '=' {
				return d == 0
			} else if c.op == '<>' {
				return d != 0
			} else if c.op == '<' {
				return d < 0
			} else if c.op == '<=' {
				return d <= 0
			} else if c.op == '>' {
				return d > 0
			} else if c.op == '>=' {
				return d >= 0
			}
			return error('fquery: bad compare op `${c.op}`')
		}
		CritIsNull {
			empty := field_val(row, c.alias, c.col) == ''
			if c.is_null {
				return empty
			}
			return !empty
		}
		CritIn {
			l := field_val(row, c.alias, c.col)
			mut hit := false
			for v in c.vals {
				if cmp_str(l, resolve_crit_val(v, bindings)!) == 0 {
					hit = true
					break
				}
			}
			if c.negate {
				return !hit
			}
			return hit
		}
		CritLike {
			s := field_val(row, c.alias, c.col)
			p := resolve_crit_val(c.pat, bindings)!
			return like_match(s, p)
		}
		CritMatch {
			s := field_val(row, c.alias, c.col)
			q := resolve_crit_val(c.q, bindings)!
			return s.to_lower().contains(q.to_lower())
		}
		CritAnd {
			for p in c.parts {
				if !(eval_crit(p, row, bindings)!) {
					return false
				}
			}
			return true
		}
		CritOr {
			for p in c.parts {
				if eval_crit(p, row, bindings)! {
					return true
				}
			}
			return false
		}
	}
}

fn validate_crit(c Crit, known map[string][]string) ! {
	match c {
		CritCmp {
			if c.alias != '' {
				check_field(c.alias, c.col, known)!
			}
		}
		CritIsNull {
			if c.alias != '' {
				check_field(c.alias, c.col, known)!
			}
		}
		CritIn {
			if c.alias != '' {
				check_field(c.alias, c.col, known)!
			}
		}
		CritLike {
			if c.alias != '' {
				check_field(c.alias, c.col, known)!
			}
		}
		CritMatch {
			if c.alias != '' {
				check_field(c.alias, c.col, known)!
			}
		}
		CritAnd {
			for p in c.parts {
				validate_crit(p, known)!
			}
		}
		CritOr {
			for p in c.parts {
				validate_crit(p, known)!
			}
		}
	}
}

// project_key validates one project entry and returns its output key.
fn project_key(item string, known map[string][]string) !string {
	name, out := split_project(item)
	if out != '' {
		if name.contains('.') {
			parts := name.split('.')
			if parts.len == 2 && parts[0].trim_space() != '' {
				check_field(parts[0].trim_space(), parts[1].trim_space(), known)!
			}
		}
		return out
	}
	if name == ':id' {
		return 'id'
	}
	if name.contains('.') {
		parts := name.split('.')
		if parts.len != 2 {
			return error('fquery: bad project `${item}` (want alias.col)')
		}
		al := parts[0].trim_space()
		co := parts[1].trim_space()
		if al != '' {
			check_field(al, co, known)!
			return co
		}
		return co
	}
	return name
}

fn project_val(item string, row Row) string {
	name, _ := split_project(item)
	if name == ':id' {
		return field_val(row, '', 'id')
	}
	if name.contains('.') {
		parts := name.split('.')
		if parts.len == 2 {
			return field_val(row, parts[0].trim_space(), parts[1].trim_space())
		}
	}
	return field_val(row, '', name)
}

fn compare_rows(a Row, b Row, keys []OrderKey) int {
	for k in keys {
		mut av := field_val(a, k.alias, k.col)
		mut bv := field_val(b, k.alias, k.col)
		if k.func == 'lower' {
			av = av.to_lower()
			bv = bv.to_lower()
		}
		d := cmp_str(av, bv)
		if d != 0 {
			if k.desc {
				return -d
			}
			return d
		}
	}
	return 0
}

// stable_sort is a merge sort over rows. sort_with_compare takes a C
// callback that cannot capture the sort keys on V 0.5.2, so the
// comparator travels as a plain argument here instead of a closure.
fn stable_sort(mut arr []Row, keys []OrderKey) {
	if arr.len < 2 {
		return
	}
	mid := arr.len / 2
	mut left := arr[..mid].clone()
	mut right := arr[mid..].clone()
	stable_sort(mut left, keys)
	stable_sort(mut right, keys)
	mut i := 0
	mut j := 0
	mut k := 0
	for i < left.len && j < right.len {
		if compare_rows(left[i], right[j], keys) <= 0 {
			arr[k] = left[i]
			i++
		} else {
			arr[k] = right[j]
			j++
		}
		k++
	}
	for i < left.len {
		arr[k] = left[i]
		i++
		k++
	}
	for j < right.len {
		arr[k] = right[j]
		j++
		k++
	}
}

// materialize runs the chain over in-memory rows: leaf is the leaf-alias
// row set, tables maps edge-target aliases to their row sets. Returns flat
// rows under the same bare keys as rows_on().
pub fn (q Query[T]) materialize(leaf []Row, tables map[string][]Row) ![]Row {
	if q.build_err != '' {
		return error(q.build_err)
	}
	mut rows := leaf.clone()
	for op in q.ops {
		match op {
			OpWhere {
				crit := parse_predicate(op.raw)!
				validate_crit(crit, q.known)!
				mut kept := []Row{}
				for r in rows {
					if eval_crit(crit, r, q.bindings)! {
						kept << r
					}
				}
				rows = kept.clone()
			}
			OpProject {
				mut keys := []string{}
				for item in op.cols {
					keys << project_key(item, q.known)!
				}
				mut projected := []Row{cap: rows.len}
				for r in rows {
					mut m := map[string]string{}
					for i, item in op.cols {
						m[keys[i]] = project_val(item, r)
					}
					projected << Row(m)
				}
				rows = projected.clone()
			}
			OpTake {
				if op.n < 0 {
					return error('fquery: take needs n >= 0')
				}
				if rows.len > op.n {
					rows = rows[..op.n]
				}
			}
			OpSkip {
				if op.n < 0 {
					return error('fquery: skip needs n >= 0')
				}
				if op.n >= rows.len {
					rows = []Row{}
				} else if op.n > 0 {
					rows = rows[op.n..]
				}
			}
			OpCount {
				rows = [Row({
					'COUNT(*)': rows.len.str()
				})]
			}
			OpOrder {
				keys := parse_order(op.raw)!
				for k in keys {
					if k.alias != '' {
						check_field(k.alias, k.col, q.known)!
					}
				}
				stable_sort(mut rows, keys)
			}
			OpEdge {
				target := tables[op.target_alias] or {
					return error('fquery: materialize needs rows for edge target `${op.target_alias}` (pass via tables)')
				}
				mut joined := []Row{}
				for l in rows {
					lv := field_val(l, op.left_alias, op.left_col)
					if lv == '' {
						continue
					}
					for r in target {
						rv := field_val(r, op.target_alias, op.right_col)
						if rv == '' {
							continue
						}
						if cmp_str(lv, rv) == 0 {
							mut m := map[string]string{}
							for k, v in l {
								m[k] = v
							}
							for k, v in r {
								m[k] = v
							}
							joined << Row(m)
						}
					}
				}
				rows = joined.clone()
			}
		}
	}
	return rows
}

// ---------------------------------------------------------------------------
// Live object graphs: the materialize_walk_obj half.
//
// Python's _obj walks the same objects in place, resolving only visited
// edges and leaving everything else (lazy properties, unvisited edges)
// live for later access. V has no awaitables to force and no attribute
// hooks, so the split falls differently here: materialize() above is the
// full eager snapshot (_walk), and the _obj half is decode-now +
// resolve-at-call-time below. Nothing is precomputed: an edge resolves
// when its accessor method is called, against an explicit TableStore.
//
//   store := fquery.new_table_store()
//   store.put('room', fquery.rows_of(db.exec('select * from rooms')!))
//   rooms := decode_all[Room](store.rows('room')!)
//   room  := membership.room_objs(store)!  // resolved HERE, not before
//
// (Transpiler note: edge accessors are per-edge concrete methods emitted
// alongside the @[edge] stubs, e.g. Membership.room_objs. Like the stubs,
// their bodies are mechanical: filter the target table on the JoinOn keys
// and decode. Python edges can run arbitrary per-item code; TableStore
// edges are key lookups, which covers every edge in the campfire app.)
// ---------------------------------------------------------------------------

// TableStore is the in-memory row source edges resolve against at call
// time. It plays the role of Python's ViewModel registry/iterators.
pub struct TableStore {
mut:
	tables map[string][]Row
}

pub fn new_table_store() TableStore {
	return TableStore{}
}

pub fn (mut s TableStore) put(alias string, rows []Row) {
	s.tables[alias] = rows
}

// rows returns the whole row set for an alias (decode it with decode_all).
pub fn (s TableStore) rows(alias string) ![]Row {
	return s.tables[alias] or { return error('fquery: table store has no rows for `${alias}`') }
}

// lookup returns target-alias rows where col matches val (numeric-aware,
// like the join and where folds; missing/empty never matches, like SQL
// NULL semantics).
pub fn (s TableStore) lookup(alias string, col string, val string) ![]Row {
	target := s.rows(alias)!
	mut out := []Row{}
	if val == '' {
		return out
	}
	for r in target {
		rv := field_val(r, alias, col)
		if rv != '' && cmp_str(rv, val) == 0 {
			out << r
		}
	}
	return out
}
