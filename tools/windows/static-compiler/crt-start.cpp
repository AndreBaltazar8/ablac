// Initialize the static MSVC CRT and LLVM's C++ globals before the Abla Windows entry.
// The Abla entry reads the Windows command line and converts it to UTF-8.
extern "C" [[noreturn]] void abla_windows_start();

extern "C" int wmain() {
    abla_windows_start();
}
