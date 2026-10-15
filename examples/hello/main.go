// hello is the smallest service an exeslim derived image can carry: no state,
// no secrets, one HTTP handler.
package main

import (
	"fmt"
	"log"
	"net/http"
)

func main() {
	http.HandleFunc("/", func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprintln(w, "hello from exeslim")
	})
	// Loopback is enough: exe.dev's proxy connects from inside the VM.
	log.Fatal(http.ListenAndServe("127.0.0.1:8000", nil))
}
