# Serial ports and device writes

`abla/device` opens native character devices on Linux and macOS. `abla/serial`
re-exports it and adds serial-port configuration. There is no libusb dependency:
Linux USB printer devices such as `/dev/usb/lp0` use the same writer as a tty.
These APIs are runtime-only; WebAssembly, freestanding targets and compile-time
device I/O are unsupported.

`deviceOpen(path, readWrite = false)` returns an affine `DeviceConnection`. Check
`opened()` and `error` before using it. It opens an existing path with
`O_WRONLY | O_NOCTTY | O_NONBLOCK | O_CLOEXEC`; `readWrite = true` selects `O_RDWR`.
It never creates or truncates a file. The opened descriptor must be a character
device: regular files and FIFOs are rejected. Device symlinks are allowed; the
check applies to the descriptor actually opened.

`close()` is idempotent, and dropping the connection closes it. Do not share a
connection between concurrent writers or change its descriptor's flags through
raw system calls. Closing does not perform an unbounded physical drain. Device
drivers must respect nonblocking writes for the deadline to bound their waits.

## Deadlines and outcomes

- `connection.writeUntil(contents, deadlineMilliseconds)` takes an **absolute
  monotonic deadline**, using the clock from `abla/process/time`.
- `connection.writeWithin(contents, timeoutMilliseconds)` takes a **relative
  timeout**. Unlike `writeUntil`, the existing networking `writeNetwork` API
  also takes a relative timeout.

Both accept binary strings, including NUL and bytes above 127, and return the
existing `NetworkWriteOutcome` from `abla/net/contracts`. Its `written` is always
the number of bytes accepted so far, including on timeout or error. Use
`succeeded()`, `timedOut()` and `failed()` to distinguish results; `error` is a
`NetworkError` with the system code, operation and category. No writes are
replayed automatically.

After the last byte is accepted, the writer waits for final `POLLOUT` readiness
within the same deadline. Linux's usblp driver requires that wait before close,
because a nonblocking write can return with a transfer still in flight. Success
means all bytes accepted **plus final readiness**. It does not mean paper was
printed or that a UART physically drained. A timeout can have
`written == contents.size`; treat that as uncertain completion rather than a
reason to replay the job. An empty write succeeds without performing I/O.

## Serial settings

`serialOpen(path, settings = SerialSettings(), readWrite = false)` opens the
same connection and configures it. If configuration fails, it closes the new
descriptor and returns an unopened connection with `error` set.
`connection.configureSerial(settings)` configures an already open connection
and returns `NetworkError`; `present()` means failure.

`SerialSettings` defaults to `baud = 9600`, `dataBits = 8`, `parity = "none"`,
`stopBits = 1`, `raw = true`, `flowControl = "none"`.

Supported settings:

- Baud: 50, 75, 110, 134, 150, 200, 300, 600, 1200, 1800, 2400, 4800, 9600,
  19200, 38400, 57600, 115200 and 230400. Hangup rate zero and custom rates are
  rejected.
- Data bits: 5 through 8; parity: `"none"`, `"even"` or `"odd"`; stop bits: 1 or 2.
- Flow control: `"none"` or `"rts-cts"`. Software XON/XOFF flow control is disabled.
- Raw mode disables terminal input/output processing, canonical input, echo and
  terminal-generated signals. `raw = false` preserves existing line processing;
  it does not reset the device to a particular cooked mode.

The configuration enables receiver/local mode and applies immediately with
`TCSANOW`. No `tcdrain`, `TCSADRAIN` or implicit input flush is used. Settings are
validated before changing the device and checked by reading them back: a driver
that rejects or coerces framing returns an error rather than a silent fallback.
For example, ptys may not implement parity or smaller character sizes. Terminal
settings belong to the device, so changes can affect other open descriptors;
a configuration failure does not promise transactional rollback.

## Receipt-printer example

This example is compiled by the documentation tests but never run: it requires
local device paths and suitable permissions. The byte sequence is illustrative
ESC/POS; use the printer's protocol and character encoding for real receipts.

```abla build
import "abla/serial"
import "abla/process/time"
import "abla/io"

fun sendUsb(receipt: string): bool {
    val printer = deviceOpen("/dev/usb/lp0")
    if (!printer.opened()) {
        eprintln("USB open failed: ${printer.error.code}")
        return false
    }
    val result = printer.writeUntil(receipt, monotonicMilliseconds() + 2000)
    printer.close()
    if (!result.succeeded()) eprintln("USB completion uncertain after ${result.written} bytes")
    result.succeeded()
}

fun sendSerial(receipt: string): bool {
    val printer = serialOpen("/dev/ttyUSB0", SerialSettings(baud = 19200))
    if (!printer.opened()) {
        eprintln("Serial open/configure failed: ${printer.error.code}")
        return false
    }
    val result = printer.writeWithin(receipt, 2000)
    printer.close()
    if (!result.succeeded()) eprintln("Serial completion uncertain after ${result.written} bytes")
    result.succeeded()
}

fun main: int {
    val receipt = "\x1b@Receipt\nTotal: EUR 12.50\n\n\n"
    if (sendUsb(receipt) && sendSerial(receipt)) 0 else 1
}
```

On macOS, use the appropriate serial device path, commonly `/dev/cu.*`. No
hardware access is part of the library's automated tests: a pty pair checks
native termios readback, exact bytes and stalled-reader deadlines.
