// Command loopland-seed is a thin wrapper kept for the container image; the same
// command runs from the module root with `go run . seed`.
package main

import (
	"os"

	"github.com/keanying/loopland/server/internal/cmd/seed"
)

func main() { seed.Main(os.Args[1:]) }
