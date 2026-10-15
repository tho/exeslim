// counter is a stateful service on exeslim: it keeps a hit counter in its
// systemd StateDirectory= and accepts a reset only with a token that systemd
// hands it through LoadCredential=.
//
//	GET  /       increments and returns the count
//	POST /reset  with "Authorization: Bearer <token>" sets it back to zero
package main

import (
	"crypto/subtle"
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
)

func main() {
	// Both set by systemd: STATE_DIRECTORY from StateDirectory=counter, as
	// /var/lib/counter; CREDENTIALS_DIRECTORY from LoadCredential=.
	path := filepath.Join(os.Getenv("STATE_DIRECTORY"), "count")
	raw, err := os.ReadFile(filepath.Join(os.Getenv("CREDENTIALS_DIRECTORY"), "token"))
	if err != nil {
		log.Fatalf("reset token: %v", err)
	}
	token := strings.TrimSpace(string(raw))
	// An empty token would match an empty Authorization header.
	if token == "" {
		log.Fatal("reset token is empty")
	}

	var mu sync.Mutex
	http.HandleFunc("GET /", func(w http.ResponseWriter, _ *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		n := load(path) + 1
		if err := save(path, n); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		fmt.Fprintln(w, n)
	})
	http.HandleFunc("POST /reset", func(w http.ResponseWriter, r *http.Request) {
		got := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		if subtle.ConstantTimeCompare([]byte(got), []byte(token)) != 1 {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		mu.Lock()
		defer mu.Unlock()
		if err := save(path, 0); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		fmt.Fprintln(w, 0)
	})
	// Loopback is enough: exe.dev's proxy connects from inside the VM.
	log.Fatal(http.ListenAndServe("127.0.0.1:8000", nil))
}

// load returns 0 for a missing or unreadable count: a fresh VM starts at zero.
func load(path string) int {
	b, err := os.ReadFile(path)
	if err != nil {
		return 0
	}
	n, _ := strconv.Atoi(strings.TrimSpace(string(b)))
	return n
}

// save writes to a temporary file and renames it over the old one, so a crash
// mid-write never leaves a truncated count.
func save(path string, n int) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, []byte(strconv.Itoa(n)+"\n"), 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
