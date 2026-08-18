// Package migrations carries the SQL schema as embedded files.
//
// The SQL lives at backend/migrations/ because that is where a human looks for
// it and what docs/PERSISTENCE.md §7 promises. go:embed, however, cannot reach
// outside the directory of the package that declares it, so rather than hiding
// the schema under internal/db/ to suit the compiler, this three-line package
// sits next to the .sql files and hands them to internal/db as a fs.FS.
//
// Nothing else belongs here. The runner -- ordering, the ledger table, the
// advisory lock -- is internal/db/migrate.go.
package migrations

import "embed"

// FS holds every numbered migration, named NNNN_description.sql. Files are
// applied in lexical order of their filename, so the number is fixed-width and
// never reused. Forward only: a mistake is corrected by a new file, never by
// editing one that has already shipped.
//
//go:embed *.sql
var FS embed.FS
