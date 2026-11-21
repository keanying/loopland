// Command loopland-api is a thin wrapper kept for the container image; the same
// command runs from the module root with `go run . `.
package main

import (
	"os"

	"github.com/keanying/loopland/server/internal/cmd/api"
)

func main() { api.Main(os.Args[1:]) }
