# Android's app seccomp policy, pinned (tools/test-android-seccomp.sh)

Android (8.0 and later) starts every app process under a seccomp-bpf filter that bionic generates (libc/tools/genseccomp.py) as

    allowed = (names in SYSCALLS.TXT for the architecture - SECCOMP_BLOCKLIST_*.TXT) + SECCOMP_ALLOWLIST_*.TXT

A system call outside it ends the app with SIGSYS. These are the source files of the bionic revisions that cover the API levels an
Abla Android library can run on with a filter: android-8.0.0_r1 (API 26), android-10.0.0_r1 (29), android-12.0.0_r1 (31),
android-14.0.0_r1 (34), android-16.0.0_r1 (36). API 24 and 25 (the library's minimum) have no app filter. The files are the
AOSP `platform/bionic` files `libc/SYSCALLS.TXT` and `libc/SECCOMP_*.TXT` at that tag (Apache License 2.0), fetched from
https://github.com/aosp-mirror/platform_bionic; android-8.0.0_r1 has one SECCOMP_WHITELIST.TXT and one SECCOMP_BLACKLIST.TXT and
android-10.0.0_r1 the same names as 12 with WHITELIST/BLACKLIST for ALLOWLIST/BLOCKLIST. `SHA256SUMS` pins every file.

`arm64-syscalls.txt`: the AArch64 system call names and numbers (Linux v6.12 `include/uapi/asm-generic/unistd.h`, GPL-2.0 WITH
Linux-syscall-note, preprocessed as its header says).
