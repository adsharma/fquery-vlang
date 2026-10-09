// Predicate and order-key language.
//
// A V port of fquery's sql_builder predicate compiler. The same strings the
// Python app passes to fq.pred()/fq.order() compile here to parameterized
// SQL: every literal becomes a `?` placeholder, user input only arrives via
// param("name") + bind(), never as SQL text.
//
// Supported predicates:
//   alias.col == value      (also !=, <>, <, <=, >, >=)
//   alias.col == None       (IS NULL; != None is IS NOT NULL)
//   alias.col is null       / is not null
//   alias.col in [1, 2, 'x'] / not in [...]   (empty list -> 1=0 / 1=1)
//   like(alias.col, pattern) / like(lower(alias.col), pattern)
//   match(alias.col, param("q"))
//   ... and ... / ... or ... / (parens)
// Values: numbers, 'single'/"double" quoted strings, None/null,
// true/false, param("name").
// Supported order keys: alias.col, lower(alias.col), desc(...),
// comma-separated for multi-key order ("a, b" like the Python tuple form).
module fquery

type Crit = CritAnd | CritCmp | CritIn | CritIsNull | CritLike | CritMatch | CritOr

struct CritAnd {
	parts []Crit
}

struct CritOr {
	parts []Crit
}

struct CritCmp {
	alias string
	col   string
	op    string
	val   Val
}

struct CritIsNull {
	alias   string
	col     string
	is_null bool
}

struct CritIn {
	alias  string
	col    string
	vals   []Val
	negate bool
}

struct CritLike {
	alias string
	col   string
	func  string // '' or 'lower'
	pat   Val
}

struct CritMatch {
	alias string
	col   string
	q     Val
}

type Val = Lit | ParamRef

struct Lit {
	text string
}

struct ParamRef {
	name string
}

struct FieldRef {
	alias string
	col   string
	func  string // '' or 'lower'
}

struct OrderKey {
	alias string
	col   string
	func  string // '' or 'lower'
	desc  bool
}

struct PParser {
	s string
mut:
	pos int
}

fn is_name_start(c u8) bool {
	return c == `_` || (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`)
}

fn is_name_char(c u8) bool {
	return is_name_start(c) || (c >= `0` && c <= `9`)
}

fn (mut p PParser) eof() bool {
	return p.pos >= p.s.len
}

fn (mut p PParser) skip_ws() {
	for !p.eof()
		&& (p.s[p.pos] == ` ` || p.s[p.pos] == `\t` || p.s[p.pos] == `\n` || p.s[p.pos] == `\r`) {
		p.pos++
	}
}

fn (mut p PParser) peek() u8 {
	if p.eof() {
		return 0
	}
	return p.s[p.pos]
}

// peek_name returns the next bare word without consuming it.
fn (mut p PParser) peek_name() string {
	mut i := p.pos
	for i < p.s.len && (p.s[i] == ` ` || p.s[i] == `\t`) {
		i++
	}
	start := i
	for i < p.s.len && is_name_char(p.s[i]) {
		i++
	}
	return p.s[start..i]
}

fn (mut p PParser) parse_name() !string {
	p.skip_ws()
	start := p.pos
	if p.eof() || !is_name_start(p.peek()) {
		return error('fquery: expected a name at offset ${p.pos} in `${p.s}`')
	}
	for !p.eof() && is_name_char(p.peek()) {
		p.pos++
	}
	return p.s[start..p.pos]
}

fn (mut p PParser) parse_number() !string {
	p.skip_ws()
	start := p.pos
	if p.peek() == `-` {
		p.pos++
	}
	mut digits := 0
	for !p.eof() && p.peek() >= `0` && p.peek() <= `9` {
		p.pos++
		digits++
	}
	if digits == 0 {
		return error('fquery: expected a number at offset ${start} in `${p.s}`')
	}
	if !p.eof() && p.peek() == `.` {
		p.pos++
		for !p.eof() && p.peek() >= `0` && p.peek() <= `9` {
			p.pos++
		}
	}
	return p.s[start..p.pos]
}

fn (mut p PParser) parse_string() !string {
	p.skip_ws()
	q := p.peek()
	if q != `'` && q != `"` {
		return error('fquery: expected a quoted string at offset ${p.pos} in `${p.s}`')
	}
	p.pos++
	mut out := ''
	for {
		if p.eof() {
			return error('fquery: unterminated string in `${p.s}`')
		}
		c := p.peek()
		if c == `\\` && p.pos + 1 < p.s.len {
			p.pos++
			out += p.s[p.pos..p.pos + 1]
			p.pos++
			continue
		}
		if c == q {
			p.pos++
			break
		}
		out += p.s[p.pos..p.pos + 1]
		p.pos++
	}
	return out
}

// parse_field parses [lower(...)]alias.col or a bare col.
fn (mut p PParser) parse_field() !FieldRef {
	p.skip_ws()
	if p.peek_name() == 'lower' {
		// Look ahead: `lower` followed by `(`.
		save := p.pos
		name := p.parse_name()!
		p.skip_ws()
		if p.peek() == `(` {
			p.pos++
			f := p.parse_dotted()!
			p.skip_ws()
			if p.peek() != `)` {
				return error('fquery: expected `)` after lower() in `${p.s}`')
			}
			p.pos++
			return FieldRef{
				alias: f.alias
				col:   f.col
				func:  'lower'
			}
		}
		p.pos = save
		_ = name
	}
	return p.parse_dotted()
}

fn (mut p PParser) parse_dotted() !FieldRef {
	first := p.parse_name()!
	p.skip_ws()
	if p.peek() == `.` {
		p.pos++
		p.skip_ws()
		second := p.parse_name()!
		return FieldRef{
			alias: first
			col:   second
		}
	}
	return FieldRef{
		alias: ''
		col:   first
	}
}

// parse_value parses a literal or param("name").
fn (mut p PParser) parse_value() !Val {
	p.skip_ws()
	c := p.peek()
	if c == `'` || c == `"` {
		return Val(Lit{
			text: p.parse_string()!
		})
	}
	if (c >= `0` && c <= `9`) || c == `-` {
		return Val(Lit{
			text: p.parse_number()!
		})
	}
	if is_name_start(c) {
		name := p.parse_name()!
		p.skip_ws()
		if name == 'param' {
			if p.peek() != `(` {
				return error('fquery: expected `(` after param in `${p.s}`')
			}
			p.pos++
			key := p.parse_string()!
			p.skip_ws()
			if p.peek() != `)` {
				return error('fquery: expected `)` after param name in `${p.s}`')
			}
			p.pos++
			return Val(ParamRef{
				name: key
			})
		}
		if name == 'None' || name == 'null' || name == 'NULL' {
			return Val(Lit{
				text: '__null__'
			})
		}
		if name == 'True' || name == 'true' {
			return Val(Lit{
				text: '1'
			})
		}
		if name == 'False' || name == 'false' {
			return Val(Lit{
				text: '0'
			})
		}
		return error('fquery: unexpected name `${name}` as a value in `${p.s}`')
	}
	return error('fquery: expected a value at offset ${p.pos} in `${p.s}`')
}

fn (mut p PParser) parse_in_list() ![]Val {
	p.skip_ws()
	if p.peek() != `[` {
		return error('fquery: expected `[` after in in `${p.s}`')
	}
	p.pos++
	mut vals := []Val{}
	p.skip_ws()
	if p.peek() == `]` {
		p.pos++
		return vals
	}
	for {
		vals << p.parse_value()!
		p.skip_ws()
		if p.peek() == `,` {
			p.pos++
			continue
		}
		if p.peek() == `]` {
			p.pos++
			break
		}
		return error('fquery: expected `,` or `]` in list in `${p.s}`')
	}
	return vals
}

fn (mut p PParser) parse_call_pred(first string) !Crit {
	// first is `like` or `match`; `(` is next.
	p.pos++ // consume `(`
	field := p.parse_field()!
	p.skip_ws()
	if p.peek() != `,` {
		return error('fquery: expected `,` in ${first}() in `${p.s}`')
	}
	p.pos++
	val := p.parse_value()!
	p.skip_ws()
	if p.peek() != `)` {
		return error('fquery: expected `)` in ${first}() in `${p.s}`')
	}
	p.pos++
	if first == 'like' {
		return Crit(CritLike{
			alias: field.alias
			col:   field.col
			func:  field.func
			pat:   val
		})
	}
	if field.func != '' {
		return error('fquery: match() takes a plain field in `${p.s}`')
	}
	return Crit(CritMatch{
		alias: field.alias
		col:   field.col
		q:     val
	})
}

fn (mut p PParser) parse_unary() !Crit {
	p.skip_ws()
	if p.peek() == `(` {
		p.pos++
		c := p.parse_or()!
		p.skip_ws()
		if p.peek() != `)` {
			return error('fquery: expected `)` in `${p.s}`')
		}
		p.pos++
		return c
	}
	// like(...)/match(...) call, or a field comparison.
	save := p.pos
	name := p.parse_name()!
	p.skip_ws()
	if p.peek() == `(` && (name == 'like' || name == 'match') {
		return p.parse_call_pred(name)!
	}
	p.pos = save
	field := p.parse_field()!
	p.skip_ws()
	word := p.peek_name()
	if word == 'is' {
		p.parse_name()!
		negate := p.peek_name() == 'not'
		if negate {
			p.parse_name()!
		}
		nul := p.parse_name()!
		if nul != 'null' && nul != 'None' && nul != 'NULL' {
			return error('fquery: expected null after is in `${p.s}`')
		}
		return Crit(CritIsNull{
			alias:   field.alias
			col:     field.col
			is_null: !negate
		})
	}
	mut negate_in := false
	if word == 'not' {
		p.parse_name()!
		negate_in = true
	}
	if p.peek_name() == 'in' {
		p.parse_name()!
		vals := p.parse_in_list()!
		return Crit(CritIn{
			alias:  field.alias
			col:    field.col
			vals:   vals
			negate: negate_in
		})
	}
	if negate_in {
		return error('fquery: `not` without `in` in `${p.s}`')
	}
	op := p.parse_cmp_op()!
	val := p.parse_value()!
	if val is Lit {
		lit := val as Lit
		if lit.text == '__null__' {
			return Crit(CritIsNull{
				alias:   field.alias
				col:     field.col
				is_null: op == '='
			})
		}
	}
	return Crit(CritCmp{
		alias: field.alias
		col:   field.col
		op:    op
		val:   val
	})
}

fn (mut p PParser) parse_cmp_op() !string {
	p.skip_ws()
	if p.eof() {
		return error('fquery: expected a comparison operator in `${p.s}`')
	}
	two := if p.pos + 1 < p.s.len { p.s[p.pos..p.pos + 2] } else { '' }
	if two == '==' || two == '!=' || two == '<=' || two == '>=' || two == '<>' {
		p.pos += 2
		if two == '==' {
			return '='
		}
		if two == '!=' {
			// Python's _cmp_ops renders NotEq as <>; match it.
			return '<>'
		}
		return two
	}
	c := p.peek()
	if c == `<` || c == `>` || c == `=` {
		p.pos++
		return c.ascii_str()
	}
	return error('fquery: expected a comparison operator at offset ${p.pos} in `${p.s}`')
}

fn (mut p PParser) parse_and() !Crit {
	mut parts := [p.parse_unary()!]
	for {
		p.skip_ws()
		if p.peek_name() != 'and' {
			break
		}
		// `and` must be a standalone word, not a name prefix.
		save := p.pos
		w := p.parse_name()!
		if w != 'and' {
			p.pos = save
			break
		}
		parts << p.parse_unary()!
	}
	if parts.len == 1 {
		return parts[0]
	}
	return Crit(CritAnd{
		parts: parts
	})
}

fn (mut p PParser) parse_or() !Crit {
	mut parts := [p.parse_and()!]
	for {
		p.skip_ws()
		if p.peek_name() != 'or' {
			break
		}
		save := p.pos
		w := p.parse_name()!
		if w != 'or' {
			p.pos = save
			break
		}
		parts << p.parse_and()!
	}
	if parts.len == 1 {
		return parts[0]
	}
	return Crit(CritOr{
		parts: parts
	})
}

fn parse_predicate(s string) !Crit {
	mut p := PParser{
		s: s
	}
	c := p.parse_or()!
	p.skip_ws()
	if !p.eof() {
		return error('fquery: trailing text at offset ${p.pos} in `${s}`')
	}
	return c
}

// parse_order splits a (possibly comma-separated) order string into keys.
fn parse_order(s string) ![]OrderKey {
	parts := split_top_level(s, `,`)!
	mut out := []OrderKey{}
	for part in parts {
		out << parse_order_key(part.trim_space())!
	}
	return out
}

// split_top_level splits on sep except inside parens/quotes.
fn split_top_level(s string, sep u8) ![]string {
	mut parts := []string{}
	mut depth := 0
	mut quote := u8(0)
	mut start := 0
	mut i := 0
	for i < s.len {
		c := s[i]
		if quote != 0 {
			if c == `\\` {
				i += 2
				continue
			}
			if c == quote {
				quote = 0
			}
			i++
			continue
		}
		if c == `'` || c == `"` {
			quote = c
		} else if c == `(` {
			depth++
		} else if c == `)` {
			depth--
			if depth < 0 {
				return error('fquery: unbalanced `)` in `${s}`')
			}
		} else if c == sep && depth == 0 {
			parts << s[start..i]
			start = i + 1
		}
		i++
	}
	if depth != 0 {
		return error('fquery: unbalanced parens in `${s}`')
	}
	parts << s[start..]
	return parts
}

fn parse_order_key(s string) !OrderKey {
	mut rest := s.trim_space()
	if rest == '' {
		return error('fquery: empty order key')
	}
	mut desc := false
	if rest.starts_with('desc(') && rest.ends_with(')') {
		desc = true
		rest = rest[5..rest.len - 1].trim_space()
	}
	mut p := PParser{
		s: rest
	}
	field := p.parse_field()!
	p.skip_ws()
	if !p.eof() {
		return error('fquery: trailing text in order key `${s}`')
	}
	return OrderKey{
		alias: field.alias
		col:   field.col
		func:  field.func
		desc:  desc
	}
}
