// svc-probe checks, from inside, that the exeslim svc- hardening profile is in
// force. Run it as svc-probe.service on an exe.dev VM whenever the drop-in
// changes (see docs/internals.md#validating-the-hardening-profile). Each check
// logs PASS or FAIL to stdout, so to the journal, followed by a summary line;
// then the same report is served on :8000.
//
// Denials must fail the way the profile makes them fail, not just fail:
// writes with EROFS (ProtectSystem=), /dev/vda with ENOENT (PrivateDevices=),
// /home unreadable (ProtectHome=; it is normally 0755), and a seccomp filter
// in force behind the mount and user namespace denials. So ordinary
// permissions alone, as for a plain unprivileged user, do not pass them.
// Positive controls (state directory and /tmp writes succeed, outbound TLS
// works) show the probe can act at all, so a check cannot pass just because
// the probe is broken.
package main

import (
	"bufio"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const tmpfsMagic = 0x01021994

type check struct {
	name string
	run  func() error // nil error means PASS
}

func main() {
	// Child mode for the user namespace check: exists only to be cloned.
	if len(os.Args) > 1 && os.Args[1] == "noop" {
		return
	}

	checks := []check{
		{"uid is not root", func() error {
			if uid := os.Getuid(); uid == 0 {
				return errors.New("running as uid 0")
			}
			return nil
		}},
		{"no groups beyond its own", func() error {
			gs, err := os.Getgroups()
			if err != nil {
				return err
			}
			for _, g := range gs {
				if g != os.Getgid() {
					return fmt.Errorf("member of gid %d", g)
				}
			}
			return nil
		}},
		{"CapEff, CapBnd, CapAmb are zero, NoNewPrivs is 1, seccomp filter in force", procStatus},
		{"write to own binary fails with EROFS", func() error {
			exe, err := os.Executable()
			if err != nil {
				return err
			}
			fi, err := os.Stat(exe)
			if err != nil {
				return err
			}
			// chmod to the current mode: a harmless write that checks for
			// a read-only mount before ownership. Opening for write would
			// report EACCES first, which any non-owner gets.
			return wantErrno(syscall.Chmod(exe, uint32(fi.Mode().Perm())), syscall.EROFS)
		}},
		{"write to /etc fails with EROFS", func() error { return wantErrno(create("/etc/svc-probe"), syscall.EROFS) }},
		{"write to /usr fails with EROFS", func() error { return wantErrno(create("/usr/svc-probe"), syscall.EROFS) }},
		{"write to $STATE_DIRECTORY succeeds", func() error {
			dir := os.Getenv("STATE_DIRECTORY")
			if dir == "" {
				return errors.New("STATE_DIRECTORY unset: unit has no StateDirectory=")
			}
			return writeRemove(filepath.Join(dir, "probe"))
		}},
		{"write to /tmp succeeds", func() error { return writeRemove("/tmp/svc-probe") }},
		{"/tmp is not tmpfs", func() error {
			var st syscall.Statfs_t
			if err := syscall.Statfs("/tmp", &st); err != nil {
				return err
			}
			if st.Type == tmpfsMagic {
				return errors.New("/tmp is RAM-backed tmpfs")
			}
			return nil
		}},
		{"AF_UNIX socket denied (EAFNOSUPPORT)", func() error {
			fd, err := syscall.Socket(syscall.AF_UNIX, syscall.SOCK_STREAM, 0)
			if err == nil {
				syscall.Close(fd)
			}
			return wantErrno(err, syscall.EAFNOSUPPORT)
		}},
		{"/dev/vda absent (ENOENT)", func() error {
			f, err := os.Open("/dev/vda")
			if err == nil {
				f.Close()
			}
			return wantErrno(err, syscall.ENOENT)
		}},
		{"/home unreadable (EACCES), so /home/exedev too", func() error {
			_, err := os.ReadDir("/home")
			return wantErrno(err, syscall.EACCES)
		}},
		// Any user without CAP_SYS_ADMIN is refused a mount, so this one
		// means little alone: the Seccomp check above shows the filter is
		// what stands behind it and the user namespace check.
		{"mount denied (EPERM)", func() error {
			dir, err := os.MkdirTemp("", "mnt")
			if err != nil {
				return err
			}
			defer os.Remove(dir)
			err = syscall.Mount("tmpfs", dir, "tmpfs", 0, "")
			if err == nil {
				syscall.Unmount(dir, 0)
			}
			return wantErrno(err, syscall.EPERM)
		}},
		{"user namespace denied (EPERM)", func() error {
			// clone(CLONE_NEWUSER) in a child: unshare() from a
			// multithreaded Go process fails with EINVAL regardless of
			// policy, which would make this check pass vacuously. EPERM
			// also rules out the child failing for an unrelated reason.
			exe, err := os.Executable()
			if err != nil {
				return err
			}
			cmd := exec.Command(exe, "noop")
			cmd.SysProcAttr = &syscall.SysProcAttr{Cloneflags: syscall.CLONE_NEWUSER}
			return wantErrno(cmd.Run(), syscall.EPERM)
		}},
		{"outbound HTTPS with certificate verification", func() error {
			c := http.Client{Timeout: 15 * time.Second}
			resp, err := c.Get("https://exe.dev/")
			if err != nil {
				return err
			}
			resp.Body.Close()
			return nil
		}},
		{"root filesystem keeps a root-only reserve", func() error {
			var st syscall.Statfs_t
			if err := syscall.Statfs("/", &st); err != nil {
				return err
			}
			if st.Bavail >= st.Bfree {
				return fmt.Errorf("avail %d >= free %d blocks: no reserve", st.Bavail, st.Bfree)
			}
			return nil
		}},
	}

	var report strings.Builder
	fails := 0
	for _, c := range checks {
		line := "PASS " + c.name
		if err := c.run(); err != nil {
			fails++
			line = fmt.Sprintf("FAIL %s: %v", c.name, err)
		}
		fmt.Println(line)
		report.WriteString(line + "\n")
	}
	summary := fmt.Sprintf("SUMMARY %d checks, %d FAIL", len(checks), fails)
	fmt.Println(summary)
	report.WriteString(summary + "\n")

	// The report is already in the journal. Exit 0 if :8000 is taken (an
	// svc- app on this VM, say): under the profile's Restart=on-failure with
	// no start limit, exiting 1 would re-run the probe forever.
	err := http.ListenAndServe("127.0.0.1:8000", http.HandlerFunc(
		func(w http.ResponseWriter, _ *http.Request) { fmt.Fprint(w, report.String()) }))
	log.Print(err)
}

// procStatus reads the kernel's view of this process's privileges.
func procStatus() error {
	f, err := os.Open("/proc/self/status")
	if err != nil {
		return err
	}
	defer f.Close()
	want := map[string]string{
		"CapEff":     "0000000000000000",
		"CapBnd":     "0000000000000000",
		"CapAmb":     "0000000000000000",
		"NoNewPrivs": "1",
		"Seccomp":    "2",
	}
	var bad []string
	filters := 0
	s := bufio.NewScanner(f)
	for s.Scan() {
		k, v, _ := strings.Cut(s.Text(), ":")
		if k == "Seccomp_filters" {
			filters, _ = strconv.Atoi(strings.TrimSpace(v))
		}
		if w, ok := want[k]; ok {
			if v = strings.TrimSpace(v); v != w {
				bad = append(bad, fmt.Sprintf("%s=%s", k, v))
			}
			delete(want, k)
		}
	}
	for k := range want {
		bad = append(bad, k+" missing")
	}
	// Observed, not documented by exe.dev: every process on the VM already
	// runs under one platform filter (Seccomp_filters is 1 in an ordinary
	// shell, 2026-10-16), so Seccomp=2 alone proves nothing there; the
	// profile adds its own on top (about 30 under systemd 255).
	if filters < 2 {
		bad = append(bad, fmt.Sprintf("Seccomp_filters=%d, want at least 2", filters))
	}
	if len(bad) > 0 {
		return errors.New(strings.Join(bad, ", "))
	}
	return nil
}

// wantErrno returns nil if err is the errno the profile produces, and
// otherwise says what happened instead.
func wantErrno(err error, want syscall.Errno) error {
	if err == nil {
		return errors.New("succeeded")
	}
	if !errors.Is(err, want) {
		return fmt.Errorf("%v, want %v", err, want)
	}
	return nil
}

// create makes path, removing it again if that worked, so a failing run
// leaves nothing behind.
func create(path string) error {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	f.Close()
	return os.Remove(path)
}

func writeRemove(path string) error {
	if err := os.WriteFile(path, []byte("probe\n"), 0o600); err != nil {
		return err
	}
	return os.Remove(path)
}
