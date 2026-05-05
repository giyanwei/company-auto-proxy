package embedded

import _ "embed"

//go:embed config.default.json
var DefaultConfigJSON []byte
