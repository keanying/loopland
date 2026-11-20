// Package migrations embeds the SQL schema files.
package migrations

import "embed"

// FS holds every *.up.sql file, applied in lexical order.
//
//go:embed *.up.sql
var FS embed.FS
