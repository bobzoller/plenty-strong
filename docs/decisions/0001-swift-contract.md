# Deterministic Swift primitives and archived source provenance

Date: 2026-10-06

These are the Task 1 implementation resolutions. The controller must confirm that
the approved plan covers these resolutions, or review them with Bob/trainer,
before policy-specific Tasks 3–5 begin. This decision does not reinterpret the
archived rules or approve a new physiological policy.

## Package boundary

`Packages/TrainingCore` is a Swift tools 6.4 library targeting iOS 18 and macOS 15.
Its production code uses Foundation and Apple's CryptoKit, with no third-party
runtime dependencies, I/O, clocks, random IDs, or executable rule callbacks.
Tests read the unchanged repository documents from `docs/specs`; those documents
are provenance, not production resources. Per the controller's explicit ruling,
Task 2 adds resource processing when its production resources exist.

## Canonical JSON

`CanonicalValue` represents only null, boolean, Int64 integer, string, array,
and object values. `CanonicalJSON.encode(_:)` emits compact UTF-8 JSON, with
object keys ordered lexicographically by Unicode scalar values and arrays in
their supplied order. Strings retain their supplied Unicode scalars; there is no
Unicode normalization or ASCII-only escaping. Quotes, backslashes, and control
characters use Python-compatible JSON escapes; slashes remain unescaped.
`sha256(_:)` returns lowercase SHA-256 hexadecimal using CryptoKit.

The archived profile is decoded directly from raw JSON and hashed after removing
only its top-level `contentHash`. Its expected digest is
`508cff9a8cc292defccd8c017da28af28007942946d268b8468f6c5a6cc8bb15`.
The archived fixture `baseInput.rules` is hashed after removing only `hash`. Its
expected digest is
`cba4084ab7e12b7074a3b87aba813f72fbff2d0560992edd0b566661bfc60beb`.
App-only additions must not change either archived serialization.

## Exact loads

`ExactLoad(canonicalAmount:)` accepts positive ASCII decimal strings with no
sign, exponent, leading integer zeros, or trailing fractional zeros. Examples
include `40`, `44.004`, and `0.1`; `0`, `01`, and `1.0` are invalid. Parsing uses
Foundation Decimal with a fixed POSIX locale and requires exact decimal-string
round-trip equality. Values that overflow, underflow, or lose precision reject.

`allowsIncrease(to:)` requires a strictly greater amount and tests
`next * 10 <= current * 11`. Every multiplication checks Foundation's result and
throws on any overflow, underflow, or loss of precision; it never rounds a
candidate into eligibility. Amounts alone are compared here. Callers must still
validate compatible units, basis, equipment catalog membership, and policy.

## Local dates

`LocalDate(iso8601:)` validates exactly `YYYY-MM-DD`, years 0001 through 9999,
using the proleptic Gregorian leap-year rules. It is comparable and encodes and
decodes as the same validated string. `adding(days:)` and `days(until:)` operate
on Gregorian day ordinals, never on elapsed seconds, a system calendar, or a
clock. Arithmetic across a daylight-saving change remains calendar-day
arithmetic. Date addition rejects range and integer overflow.

Adapters converting instants to local dates must supply an explicit timezone;
the pure date primitive has no implicit timezone and performs no instant
conversion. Interruption policy, including its 28-day threshold, belongs to
later tasks.

## Unchanged source bytes

The bootstrap copied these source documents unchanged. Their SHA-256 byte
checksums recorded and rechecked during Task 1 are:

| Repository source | SHA-256 bytes |
| --- | --- |
| `docs/specs/2026-10-05-fixed-exercise-profile.json` | `f8fc88335a9c8d64ac5fa9f5a4b90bfc44cbbd4327c1ab48a73a6ada995449ee` |
| `docs/specs/2026-10-05-fixed-exercise-selection-design.md` | `aebccde00e63667c327fc0d8c6a55cb19d416035a5ee8ae861dcd6e2ae4436c4` |
| `docs/specs/2026-10-05-general-fitness-progression-design.md` | `a09c3e0f020389571b4bde78cc0611c4bfd6b43adba9fc38e4ac2d43721b7f13` |
| `docs/specs/2026-10-05-general-fitness-progression-examples.json` | `fa6b58ac5aa1b89c22f4915316e99f0d773f339673332328bbf562c34838f38b` |

No utility implementation was copied from Kado or another project. MIT remains
the proposed project license; later copied MIT code must retain its attribution.
