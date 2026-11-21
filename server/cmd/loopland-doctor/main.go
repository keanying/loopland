// Command loopland-doctor is a thin wrapper kept for the container image; the same
// command runs from the module root with `go run . doctor`.
package main

import (
	"os"

	"github.com/keanying/loopland/server/internal/cmd/doctor"
)

func main() { doctor.Main(os.Args[1:]) }
