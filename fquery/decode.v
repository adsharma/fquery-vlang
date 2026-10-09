// Typed row decoding: fill a struct from a Row using its compile-time
// field list. No per-entity boilerplate; unknown/missing columns read as
// zero values. Field types drive the conversion, and @[col] overrides
// resolve through the same field_col mapping as query validation.
//
// Two shapes (V 0.5.2 only allows type params mentioned in a pub fn's
// args/return, so cross-type decode is a free function over rows):
//   users := new_user_query()...to_structs(&db)!      // leaf type == row type
//   entries := decode_all[Entry](rows)              // any row type
module fquery

pub fn decode_row[U](row Row) U {
	mut u := U{}
	$for f in U.fields {
		v := row[field_col(f.name, f.attrs)]
		$if f.typ is int {
			u.$(f.name) = v.int()
		} $else $if f.typ is i64 {
			u.$(f.name) = v.i64()
		} $else $if f.typ is f64 {
			u.$(f.name) = v.f64()
		} $else $if f.typ is bool {
			u.$(f.name) = v == '1' || v.to_lower() == 'true'
		} $else $if f.typ is string {
			u.$(f.name) = v
		}
	}
	return u
}

pub fn decode_all[U](rows []Row) []U {
	mut out := []U{cap: rows.len}
	for r in rows {
		out << decode_row[U](r)
	}
	return out
}

// count_value reads the 'COUNT(*)' cell of a count() chain result.
pub fn count_value(rows []Row) int {
	if rows.len == 0 {
		return 0
	}
	return rows[0]['COUNT(*)'].int()
}
