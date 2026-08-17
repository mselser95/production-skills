// Package domain is the pure decision core of this service: the units
// ledger. Nothing in this package performs I/O, reads the wall clock,
// generates randomness, or starts a goroutine — see
// internal/architecture/boundaries_test.go, which enforces all of that
// mechanically, not by convention.
//
// Money is represented as DECIMAL STRINGS, never float64: a float cannot
// represent 0.1 exactly, and repeated addition/subtraction of float
// approximations is exactly how a ledger silently drifts. Every amount is
// parsed to a fixed-point integer (scale 8, i.e. up to 8 fractional digits —
// a satoshi-like precision chosen so the example domain can represent
// fractional units without pulling in an arbitrary-precision decimal
// dependency; go.mod stays stdlib-only) via math/big, operated on as
// integers, and re-rendered as a canonical decimal string. This is the
// "decode boundary" FuzzParseAmount exists for: untrusted decimal strings
// arrive from callers (deposit/withdraw amounts) and must never panic or
// silently misparse, whatever garbage is thrown at them.
package domain

import (
	"errors"
	"math/big"
	"strings"
)

// Scale is the fixed number of fractional decimal digits every amount in
// this ledger carries. Chosen once, for the whole domain — mixing scales
// would make comparison ambiguous, which is exactly the bug class fixed-
// point representations exist to rule out.
const Scale = 8

// ErrMalformedAmount is returned by ParseAmount for any input that is not a
// plain, non-negative, base-10 decimal string with at most Scale fractional
// digits (no signs, no exponents, no whitespace, no thousands separators —
// the ledger's boundary format is deliberately narrow so a malformed value
// fails loudly here rather than being "helpfully" coerced downstream).
var ErrMalformedAmount = errors.New("domain: malformed amount")

// ErrNegativeAmount is returned by ParseAmount for a syntactically valid but
// negative decimal string. Amounts in this domain are always non-negative
// quantities; direction (deposit adds, withdraw subtracts) is carried by the
// Event's Type, never by the sign of Amount.
var ErrNegativeAmount = errors.New("domain: negative amount")

// ErrTooManyFractionalDigits is returned when the input carries more than
// Scale digits after the decimal point — silently truncating precision the
// caller asked for would be a rounding bug wearing a parser's clothes.
var ErrTooManyFractionalDigits = errors.New("domain: more than 8 fractional digits")

// ParseAmount validates and parses a decimal string into fixed-point integer
// units (amount * 10^Scale). It is the sole decode boundary for every
// caller-supplied amount in this domain — FuzzParseAmount drives it directly
// with adversarial input.
//
// Accepted grammar: `-?[0-9]+(\.[0-9]{1,8})?` restricted to non-negative
// (see ErrNegativeAmount) — i.e. effectively `[0-9]+(\.[0-9]{1,8})?`, ASCII
// digits only. Anything else — empty string, "+1", "1e10", "1,000", leading/
// trailing whitespace, unicode digits, "NaN", "Inf" — is ErrMalformedAmount.
func ParseAmount(s string) (*big.Int, error) {
	if s == "" {
		return nil, ErrMalformedAmount
	}
	if strings.HasPrefix(s, "-") {
		return nil, ErrNegativeAmount
	}
	intPart, fracPart, hasFrac := strings.Cut(s, ".")
	if intPart == "" {
		return nil, ErrMalformedAmount
	}
	if !isASCIIDigits(intPart) {
		return nil, ErrMalformedAmount
	}
	if hasFrac {
		if fracPart == "" || !isASCIIDigits(fracPart) {
			return nil, ErrMalformedAmount
		}
		if len(fracPart) > Scale {
			return nil, ErrTooManyFractionalDigits
		}
	}
	// Reject a second "." (strings.Cut only ever splits on the FIRST ".",
	// so "1.2.3" would otherwise parse fracPart="2.3" and fail the digits
	// check above already -- this branch is unreachable but documents why
	// Cut alone is sufficient rather than a stricter regex).
	fracPadded := fracPart + strings.Repeat("0", Scale-len(fracPart))

	units := new(big.Int)
	if _, ok := units.SetString(intPart+fracPadded, 10); !ok {
		return nil, ErrMalformedAmount
	}
	return units, nil
}

func isASCIIDigits(s string) bool {
	for _, r := range s {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

// FormatAmount renders fixed-point integer units back to the canonical
// decimal string form ParseAmount accepts (no leading zeros in the integer
// part beyond a single "0", always exactly Scale fractional digits, no
// trailing-zero trimming — a canonical, unambiguous, round-trippable
// representation). units must be non-negative; FormatAmount panics on a
// negative value because it is a programming error for this domain's own
// non-negative-only amount type to ever hold one (every path that could
// produce a negative units.Int is guarded before it reaches here — see
// AddAmounts/SubAmounts).
func FormatAmount(units *big.Int) string {
	if units.Sign() < 0 {
		panic("domain: FormatAmount called with a negative value")
	}
	s := new(big.Int).Abs(units).String()
	for len(s) <= Scale {
		s = "0" + s
	}
	intPart := s[:len(s)-Scale]
	fracPart := s[len(s)-Scale:]
	return intPart + "." + fracPart
}

// AddAmounts returns a+b as a canonical decimal string. Both inputs must be
// valid ParseAmount-shaped decimal strings.
func AddAmounts(a, b string) (string, error) {
	au, err := ParseAmount(a)
	if err != nil {
		return "", err
	}
	bu, err := ParseAmount(b)
	if err != nil {
		return "", err
	}
	sum := new(big.Int).Add(au, bu)
	return FormatAmount(sum), nil
}

// ErrInsufficientAmount is returned by SubAmounts when b > a: this domain's
// amounts (balances included) are never negative, so a subtraction that
// would go negative is a rejected operation, not a signed result.
var ErrInsufficientAmount = errors.New("domain: subtrahend exceeds minuend")

// SubAmounts returns a-b as a canonical decimal string, or
// ErrInsufficientAmount if b > a.
func SubAmounts(a, b string) (string, error) {
	au, err := ParseAmount(a)
	if err != nil {
		return "", err
	}
	bu, err := ParseAmount(b)
	if err != nil {
		return "", err
	}
	if bu.Cmp(au) > 0 {
		return "", ErrInsufficientAmount
	}
	diff := new(big.Int).Sub(au, bu)
	return FormatAmount(diff), nil
}

// CompareAmounts returns -1, 0, or 1 as a < b, a == b, a > b. Both inputs
// must be valid ParseAmount-shaped decimal strings.
func CompareAmounts(a, b string) (int, error) {
	au, err := ParseAmount(a)
	if err != nil {
		return 0, err
	}
	bu, err := ParseAmount(b)
	if err != nil {
		return 0, err
	}
	return au.Cmp(bu), nil
}

// ValidateAmount reports whether s is a well-formed, non-negative amount
// string, without needing the caller to discard the parsed value.
func ValidateAmount(s string) error {
	_, err := ParseAmount(s)
	return err
}

// ZeroAmount is the canonical zero-value decimal string this domain uses as
// the initial ledger balance.
const ZeroAmount = "0.00000000"
