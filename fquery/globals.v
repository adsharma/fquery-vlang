module fquery

import db.sqlite

// The ambient connection is the open handle (bool + pointer), so holding
// it by value shares the live connection, mirroring fquery.env.use().
__global g_db sqlite.DB
__global g_db_set bool

pub fn use_db(db sqlite.DB) {
	g_db = db
	g_db_set = true
}

fn ambient_db() !&sqlite.DB {
	if !g_db_set {
		return error('fquery: no ambient connection: use_db() first')
	}
	return &g_db
}
