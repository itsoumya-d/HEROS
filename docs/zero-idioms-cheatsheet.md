# Zero Language Idioms Cheatsheet

*Version: zerolang.ai v0.1.1 (May 2026) — re-verify each session*

---

## 1. Project Setup

```bash
zero new cli <name>        # scaffold project
zero check .               # type-check
zero run .                 # execute
zero test .                # run tests
zero build --target linux-musl-x64 --out .zero/out/binary .
zero size --json --profile tiny --target linux-musl-x64 .
zero graph --json .        # module dependency graph
zero routes --json .       # web route inspection
zero targets               # list supported targets
zero fix --plan --json .   # auto-repair suggestions
zero explain <CODE>        # explain a diagnostic code
zero doctor                # environment diagnostics
```

### zero.json (CLI)
```json
{
  "package": { "name": "mypkg", "version": "0.1.0" },
  "targets": {
    "cli": { "kind": "exe", "main": "src/main.0" }
  }
}
```

### zero.json (Web)
```json
{
  "package": { "name": "mypkg", "version": "0.1.0" },
  "targets": {
    "web": { "kind": "web", "runtime": "wasm32-web", "routes": "src/routes" }
  }
}
```

### Source layout
```
src/
  main.0
  helpers.0
  config/
    parser.0      # imported as: use config.parser
zero.json
```

---

## 2. Entry Point & World

```zero
pub fun main(world: World) -> Void raises {
    check world.out.write("hello\n")     // stdout
    check world.err.write("warning\n")  // stderr
}
```

- `World` is the capability object. Not a global. Passed as parameter. Cannot be created in user code.
- `pub` exports the symbol as an entry point.
- `raises` (no set = raises anything) is required when calling any `check` expression.
- `raises { ErrorA, ErrorB }` narrows the declared error set.

---

## 3. Core Types

| Type | Description |
|------|-------------|
| `i8 i16 i32 i64` | Signed integers |
| `u8 u16 u32 u64 usize isize` | Unsigned / size integers |
| `f32 f64` | Floats (untyped float literals default to `f64`) |
| `char` | Single-byte ASCII literal — does NOT cast to/from integers |
| `Bool` | Conditions MUST be `Bool`; no truthy coercion |
| `Void` | No return value |
| `String` | UTF-8 string |
| `[N]T` | Fixed-size array — must be manually zero-initialized |
| `Span<T>` | Read-only contiguous view |
| `MutSpan<T>` | Mutable contiguous view |
| `Maybe<T>` | Optional — has `.has: Bool` and `.value: T` |
| `ref<T>` | Immutable borrow (`&value`) |
| `mutref<T>` | Mutable borrow (`&mut value`) |
| `owned<T>` | Heap resource with drop() cleanup; auto-cleans via defer |

### Literals
```zero
42          // i32 (context-typed)
42_u8       // explicit u8 suffix
0xDEAD_u32  // hex with separator
0b1010_u8   // binary
0o777_usize // octal
1.0         // f64
'a'         // char
"hello"     // String
```

### Type cast (primitives only)
```zero
let b: u8 = count as u8   // explicit, no implicit coercion
```

### Type alias
```zero
pub type ByteCount = usize   // compile-time alias, no runtime overhead
```

---

## 4. Shape (Struct)

```zero
shape Point {
    x: i32,
    y: i32,
}

shape Config {
    host: String,
    port: u16 = 8080,     // field default
    debug: Bool = false,
}

shape Pair<T, U> {        // generic shape
    left: T,
    right: U,
}
```

---

## 5. Enum

```zero
enum Status { ready, failed, pending }
```

Enums are fixed symbol sets. Use in match, choice payloads, generic static params.

---

## 6. Choice (Tagged Union)

```zero
choice Result {
    ok: i32,
    err: String,
}

let r: Result = Result.ok(42)
let e: Result = Result.err("bad input")
```

---

## 7. Match (Exhaustive)

```zero
match result {
    .ok => value {
        // value: i32
    }
    .err => msg {
        // msg: String
    }
}
```

All arms must be covered — compiler enforces exhaustiveness.

---

## 8. Error Handling

```zero
fun validate(n: i32) -> i32 raises { InvalidInput } {
    if n < 0 { raise InvalidInput }
    return n
}

pub fun main(world: World) -> Void raises {
    let x = check validate(-1)   // propagates InvalidInput up
}
```

- `raises { A, B }` — declare which errors can escape this function
- `raise ErrorName` — emit an error (like throw, but no exceptions)
- `check expr` — if expr fails, propagate error to caller (like `?` in Rust)
- Enclosing function MUST declare `raises` to use `check`
- Errors lower to direct branches + small status structs — zero runtime overhead

### Two patterns: raising vs non-raising
```zero
// Raising: use check, must handle in caller
let file: owned<File> = check std.fs.openOrRaise(fs, path)

// Non-raising: returns Maybe<T>
let file = std.fs.create(fs, path)   // Maybe<owned<File>>
if file.has {
    let mut f: owned<File> = file.value
}
```

---

## 9. Variables

```zero
let x = 42           // immutable
let mut count = 0    // mutable
count = count + 1
```

Use `let mut` ONLY when reassignment is needed — compiler enforces.

---

## 10. Functions & Generics

```zero
fun add(a: i32, b: i32) -> i32 {
    return a + b
}

fun identity<T>(value: T) -> T {
    return value
}

// Static value parameters (integers, Bool, enum cases)
fun first<T, static N: usize>(vec: ref<FixedVec<T,N>>) -> T {
    return vec.items[0]
}
```

---

## 11. Control Flow

```zero
if condition { } else { }          // condition must be Bool

while condition { }

for index in 0..10 {               // half-open range
    if index == 5 { continue }
    if index == 8 { break }
}

defer cleanup()                    // runs on scope exit (return, break, continue)
```

---

## 12. Imports

```zero
use std.codec             // standard library
use helpers               // → src/helpers.0
use config.parser         // → src/config/parser.0 (or mod.0)
```

---

## 13. std.mem

```zero
let span = std.mem.span("text")           // Span<u8> from string literal
let eql = std.mem.eql(span_a, span_b)    // Bool, byte-wise equality
let bytes = std.mem.bufBytes(&buf)        // Span<u8> from &owned<ByteBuf>

let mut storage: [64]u8 = [0, ...]       // stack buffer
let mut alloc = std.mem.fixedBufAlloc(storage)  // bump allocator over stack
```

---

## 14. std.args

```zero
let count = std.args.len()            // usize — total argument count
let arg = std.args.get(1)            // Maybe<String> — 0 = program name
if arg.has {
    let val: String = arg.value
}
```

**Note:** `std.args` is minimal — index-based only. No flag parsing built in as of v0.1.1. Build flag parsing with `std.parse` or your own shape-based parser.

---

## 15. std.fs

```zero
let fs = std.fs.host()   // get filesystem capability

// Read all into owned buffer (non-raising, returns Maybe)
let body = std.fs.readAll(alloc, fs, path, maxBytes)
// body: Maybe<owned<ByteBuf>>

// Read all (raising variant)
let mut buf: owned<ByteBuf> = check std.fs.readAllOrRaise(alloc, fs, path, maxBytes)
let bytes = std.mem.bufBytes(&buf)

// Create and write (raising)
let mut file: owned<File> = check std.fs.createOrRaise(fs, path)
check std.fs.writeAllOrRaise(&mut file, data_span)
let written = check std.fs.fileLenOrRaise(&mut file)
std.fs.close(&mut file)

// Create (non-raising)
let created = std.fs.create(fs, path)   // Maybe<owned<File>>
if created.has {
    let mut f: owned<File> = created.value
    // use std.fs.writeAll(&mut f, span) -> Bool
}

// Open and read (raising)
let mut opened: owned<File> = check std.fs.openOrRaise(fs, path)
let read_len: usize = check std.fs.readOrRaise(&mut opened, mut_buf)
```

**Capability gating:** `std.fs` requires host target. On `wasm32-web` or other non-host targets, the compiler rejects it with `TAR002`.

---

## 16. std.path

```zero
std.path.basename("src/main.0")      // "main.0"  (String)
std.path.dirname("src/main.0")       // "src"
std.path.extension("src/main.0")     // "0"

let mut buf: [64]u8 = [0, ...]
let joined = std.path.join(buf, "src", "main.0")        // Maybe<String>
let normed = std.path.normalize(buf, "src//./main.0/")  // Maybe<String>
let rel    = std.path.relative(buf, "src", "src/main.0") // Maybe<String>
```

---

## 17. std.codec

```zero
std.codec.crc32("text")           // u32 — CRC-32 of string
std.codec.crc32Bytes(span)        // u32 — CRC-32 of Span<u8>
std.codec.readU32("abcd")         // u32 — 4 bytes as u32
std.codec.readU16("ab")           // u16 — 2 bytes as u16
std.codec.encodedVarintLen(300)   // usize — varint length of value
```

---

## 18. std.parse

```zero
std.parse.isAsciiDigit("7")        // Bool
std.parse.isIdentifierStart("_")   // Bool
std.parse.scanDigits("123abc")     // usize — count of leading digits
```

---

## 19. std.time

```zero
let ms   = std.time.ms(500)
let secs = std.time.seconds(2)
let sum  = std.time.add(ms, secs)
let diff = std.time.sub(secs, ms)
let ms_val = std.time.asMsFloor(sum)   // i64
let mono = std.time.monotonic()        // monotonic timestamp
let wall = std.time.wallSeconds()      // i64 wall clock seconds
```

---

## 20. std.rand

```zero
let mut rng = std.rand.seed(7_u32)     // deterministic RNG
let v1 = std.rand.nextU32(&mut rng)   // u32
let v2 = std.rand.nextU32(&mut rng)   // different from v1
let entropy = std.rand.entropyU32()   // OS entropy source, u32
```

---

## 21. std.crypto

```zero
std.crypto.hash32(std.mem.span("msg"))                    // u32 hash
std.crypto.hmac32(std.mem.span("key"), std.mem.span("msg")) // u32 HMAC
std.crypto.secureRandomU32()                               // u32 from OS CSPRNG
std.crypto.constantTimeEql(span_a, span_b)                // Bool — timing-safe
```

---

## 22. std.proc

```zero
let status = std.proc.spawn("command")    // spawn process
let code   = std.proc.exitCode(status)   // i32 exit code
```

---

## 23. std.io

```zero
let mut buf: [8]u8 = [0, ...]
let reader = std.io.bufferedReader(buf)
let writer = std.io.bufferedWriter(buf)
let cap = std.io.readerCapacity(&reader)   // usize
let cap2 = std.io.writerCapacity(&writer)  // usize
let copied = std.io.copy(dst_buf, src_span)  // usize bytes copied
```

---

## 24. std.env

```zero
// Expected API based on reference listing (verify against actual docs):
let val = std.env.get("HOME")   // likely Maybe<String>
```

---

## 25. std.json

```zero
// Listed in reference but specific API not yet documented in public examples.
// Expected (verify): parse JSON string into shapes/choices, emit shapes as JSON.
// Critical for agent-facing tools — use on every agent boundary.
```

---

## 26. C Interop

```zero
extern c "config.h" as config
extern shape CConfig {
    enabled: bool,
    limit: i32,
}
```

---

## 27. Web Handlers

```zero
pub fun GET(req: Request) -> Response {
    return Response.text("hello\n")
}
```

---

## 28. Tests

```zero
test "addition is stable" {
    expect(40 + 2 == 42)
}
```

Run: `zero test .` or `zero test --json --filter "addition" .`

---

## 29. Supported Targets

| Target | Description |
|--------|-------------|
| `linux-musl-x64` | **Primary agent target** — static, no libc dep |
| `linux-musl-arm64` | ARM musl static |
| `linux-arm64` | Linux ARM glibc |
| `darwin-arm64` | macOS Apple Silicon |
| `darwin-x64` | macOS Intel |
| `win32-x64.exe` | Windows x64 |
| `win32-arm64.exe` | Windows ARM64 |

---

## 30. Sharp Edges

1. **Array initialization is manual** — `[N]u8 = [0, 0, ...]` — no shorthand zero-fill yet
2. **Conditions must be Bool** — `if 1 { }` is a compile error; `if count > 0 { }` is required
3. **`check` requires `raises` on enclosing function** — forgetting `raises` causes a confusing error
4. **Bounds abort, not panic-catch** — runtime bounds failure prints `"zero bounds check failed"` and aborts; no way to catch it
5. **`std.fs` is capability-gated** — using it in a non-host target produces `TAR002` at compile time
6. **`char` does not convert to integers** — use `u8` for byte manipulation
7. **`let` is strict immutable** — reassigning a `let` binding is a compile error
8. **`std.args` is index-only** — no flag parser; roll your own with `std.parse`
9. **`String` vs `Span<u8>`** — most std functions operate on spans; convert with `std.mem.span(str)` where needed
10. **Errors must be declared** — `raise UnknownError` when `UnknownError` is not in the `raises` set is a compile error
11. **`owned<T>` requires explicit close** — `std.fs.close(&mut file)` or defer it; the compiler may warn on un-closed owned values
12. **No implicit async** — all I/O is synchronous; there is no built-in async/await or event loop

---

## 31. Agent-Native CLI Pattern (Target Pattern)

```zero
// src/main.0
use std.args
use std.json   // for --json output
use describe   // your schema module

pub fun main(world: World) -> Void raises {
    let arg1 = std.args.get(1)
    if arg1.has {
        if std.mem.eql(std.mem.span(arg1.value), std.mem.span("--describe")) {
            // emit machine-readable schema
            check world.out.write(describe.schema())
            return
        }
        if std.mem.eql(std.mem.span(arg1.value), std.mem.span("--version")) {
            check world.out.write("1.0.0\n")
            return
        }
    }
    // core logic...
}
```

```bash
# Build agent-deployable binary
zero build --target linux-musl-x64 --profile tiny --out .zero/out/tool .
zero size --json --profile tiny --target linux-musl-x64 .
```

---

## 32. Build Profiles

```bash
zero build --profile debug ...   # debug info, no optimization
zero build --profile tiny ...    # aggressive size optimization (target: sub-100 KiB)
zero build ...                   # default (release)
```
