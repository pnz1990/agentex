// Package roledefs provides the embedded role YAML definitions.
// This package exists at the roles/ directory level so it can use go:embed
// to include the YAML files that live alongside it.
package roledefs

import "embed"

// FS contains all role definition YAML files embedded at compile time.
//
//go:embed *.yaml
var FS embed.FS
