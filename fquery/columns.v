// Field-level column mapping.
//
// A struct field maps to the SQL column of the same name, unless it
// carries a field-level @[col: '...'] attribute:
//
//   struct Room {
//     room_type string @[col: 'type']
//   }
//
// Both the known-column registry (query validation) and the typed row
// decoder resolve columns through field_col, so the declaration is the
// single source of truth — the V equivalent of Python's declarative
// field mapping, read at compile time via $for/f.attrs.
module fquery

// field_col resolves one field to its SQL column name.
pub fn field_col(fname string, attrs []string) string {
	for a in attrs {
		t := a.trim_space()
		if t.starts_with('col:') {
			return t[4..].trim_space().trim('\'"')
		}
	}
	return fname
}

// columns_of returns every column of T in field order.
pub fn columns_of[T]() []string {
	mut out := []string{}
	$for f in T.fields {
		out << field_col(f.name, f.attrs)
	}
	return out
}
