// sandbox-probe checks, from inside a svc- unit, that the hardening profile's
// filter passes the seccomp and Landlock system calls and that the kernel
// enforces a Landlock ruleset. On a kernel without Landlock it checks the
// filter alone and says so. See docs/developing.md.
package main

import (
	"errors"
	"fmt"
	"os"
	"runtime"
	"syscall"
	"unsafe"
)

const (
	// Landlock's system call numbers are the same on every architecture.
	sysLandlockCreateRuleset = 444
	sysLandlockAddRule       = 445
	sysLandlockRestrictSelf  = 446

	landlockCreateRulesetVersion = 1 << 0
	landlockRulePathBeneath      = 1
	landlockAccessFSReadFile     = 1 << 2

	prSetNoNewPrivs       = 38
	seccompGetActionAvail = 2
	seccompRetAllow       = 0x7fff0000

	target = "/etc/passwd"
)

// A blocked call fails with EPERM, the profile's SystemCallErrorNumber=.
const filterHint = "EPERM means the unit's SystemCallFilter=, EOPNOTSUPP or ENOSYS the kernel"

func fail(format string, a ...any) {
	fmt.Fprintf(os.Stderr, "sandbox-probe: "+format+"\n", a...)
	os.Exit(1)
}

func sysSeccomp() uintptr {
	switch runtime.GOARCH {
	case "amd64":
		return 317
	case "arm64":
		return 277
	}
	fail("no seccomp(2) number for %s", runtime.GOARCH)
	return 0
}

func main() {
	fmt.Println("uid", os.Getuid())

	// Asks whether an action is available, which changes nothing.
	action := uint32(seccompRetAllow)
	if _, _, e := syscall.Syscall(sysSeccomp(), seccompGetActionAvail, 0, uintptr(unsafe.Pointer(&action))); e != 0 {
		fail("seccomp(2): %v (%s)", e, filterHint)
	}
	fmt.Println("seccomp allowed")

	abi, _, e := syscall.Syscall(sysLandlockCreateRuleset, 0, 0, landlockCreateRulesetVersion)
	if e == syscall.EOPNOTSUPP || e == syscall.ENOSYS {
		// The kernel has no Landlock, or has it switched off. The filter runs
		// before the kernel answers, so the other two calls still show it.
		bad := -1
		if _, _, e := syscall.Syscall6(sysLandlockAddRule, uintptr(bad), landlockRulePathBeneath, 0, 0, 0, 0); e == syscall.EPERM {
			fail("landlock_add_rule: %v (%s)", e, filterHint)
		}
		if _, _, e := syscall.Syscall(sysLandlockRestrictSelf, uintptr(bad), 0, 0); e == syscall.EPERM {
			fail("landlock_restrict_self: %v (%s)", e, filterHint)
		}
		fmt.Println("landlock unavailable:", e)
		return
	}
	if e != 0 {
		fail("landlock_create_ruleset: %v (%s)", e, filterHint)
	}
	fmt.Println("landlock abi", abi)

	// No descriptor: the kernel answers EBADF, the filter EPERM.
	bad := -1
	if _, _, e := syscall.Syscall6(sysLandlockAddRule, uintptr(bad), landlockRulePathBeneath, 0, 0, 0, 0); e != syscall.EBADF {
		fail("landlock_add_rule: %v, want EBADF (%s)", e, filterHint)
	}

	if _, err := os.ReadFile(target); err != nil {
		fail("%s is not readable to begin with: %v", target, err)
	}

	// Handles file reads and allows none, so any read is refused.
	attr := struct{ handledAccessFS uint64 }{landlockAccessFSReadFile}
	fd, _, e := syscall.Syscall(sysLandlockCreateRuleset, uintptr(unsafe.Pointer(&attr)), unsafe.Sizeof(attr), 0)
	if e != 0 {
		fail("landlock_create_ruleset with a ruleset: %v", e)
	}
	// Every thread, not only this one: Go runs on several. Needs CGO_ENABLED=0.
	if _, _, e := syscall.AllThreadsSyscall(syscall.SYS_PRCTL, prSetNoNewPrivs, 1, 0); e != 0 {
		fail("prctl(PR_SET_NO_NEW_PRIVS): %v", e)
	}
	if _, _, e := syscall.AllThreadsSyscall(sysLandlockRestrictSelf, fd, 0, 0); e != 0 {
		fail("landlock_restrict_self: %v", e)
	}

	_, err := os.ReadFile(target)
	if !errors.Is(err, os.ErrPermission) {
		fail("%s after landlock_restrict_self: %v, want permission denied", target, err)
	}
	fmt.Println("landlock enforced")
}
