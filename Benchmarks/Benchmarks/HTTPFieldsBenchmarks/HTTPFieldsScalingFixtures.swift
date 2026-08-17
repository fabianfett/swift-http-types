//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import HTTPTypes

// MARK: - Field lists

/// Field lists of increasing size, used to measure how `HTTPFields` operations scale.
///
/// The lists are nested: every list is a prefix of the next larger one, so a difference between two
/// sizes is only ever caused by the fields that were added, never by the fields that were already
/// there.
///
/// Real field lists grow past ~16 fields almost exclusively because of cookies, so that is how these
/// grow too: the ordinary headers stop at 16 and everything beyond that is a `Cookie` field. The two
/// sizes therefore vary independently — the total number of fields keeps growing while the number of
/// distinct names does not — and comparing the small sizes against the large ones shows which of the
/// two a given operation is sensitive to.

/// `Cookie` fields with distinct values, so that no two fields in a list compare equal.
private func cookieFields(_ range: Range<Int>) -> [HTTPField] {
    range.map { HTTPField(name: .cookie, value: "cookie\($0)=aBcDeF0123456789-\($0)") }
}

/// A name that has no static member on `HTTPField.Name`.
private func name(_ string: String) -> HTTPField.Name {
    HTTPField.Name(string)!
}

/// 6 ordinary headers and 2 cookies.
let scalingFields8: [HTTPField] =
    [
        HTTPField(name: .connection, value: "keep-alive"),
        HTTPField(name: .userAgent, value: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"),
        HTTPField(name: .accept, value: "text/html,application/xhtml+xml,application/xml;q=0.9"),
        HTTPField(name: .acceptEncoding, value: "gzip, deflate, br"),
        HTTPField(name: .acceptLanguage, value: "en-US,en;q=0.9"),
        HTTPField(name: .referer, value: "https://www.example.com/home"),
    ] + cookieFields(0..<2)

/// 12 ordinary headers and 4 cookies.
let scalingFields16: [HTTPField] =
    scalingFields8 + [
        HTTPField(name: .origin, value: "https://www.example.com"),
        HTTPField(name: .cacheControl, value: "no-cache"),
        HTTPField(name: name("sec-fetch-dest"), value: "document"),
        HTTPField(name: name("sec-fetch-mode"), value: "navigate"),
        HTTPField(name: name("sec-fetch-site"), value: "same-origin"),
        HTTPField(name: .te, value: "trailers"),
    ] + cookieFields(2..<4)

/// 16 ordinary headers and 16 cookies.
let scalingFields32: [HTTPField] =
    scalingFields16 + [
        HTTPField(name: .authorization, value: "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"),
        HTTPField(name: .ifNoneMatch, value: "\"686897696a7c876b7e\""),
        HTTPField(name: .ifModifiedSince, value: "Mon, 03 Aug 2026 12:00:00 GMT"),
        HTTPField(name: .priority, value: "u=0, i"),
    ] + cookieFields(4..<16)

/// 16 ordinary headers and 48 cookies.
let scalingFields64: [HTTPField] = scalingFields32 + cookieFields(16..<48)

/// 16 ordinary headers and 112 cookies.
let scalingFields128: [HTTPField] = scalingFields64 + cookieFields(48..<112)

// MARK: - Building

/// Builds an `HTTPFields` by appending, which is how one is built on a receive path.
///
/// Fixtures that are compared against each other are always built by two separate calls to this
/// function, never by copying one into the other, so that the two values are genuinely distinct and
/// equality cannot take a shortcut for two copies of the same value.
private func makeFields(_ fields: [HTTPField]) -> HTTPFields {
    var result = HTTPFields()
    for field in fields {
        result.append(field)
    }
    // Read the value once before handing it out, so that any work `HTTPFields` defers until its
    // first read is not charged to whichever benchmark happens to run first.
    precondition(result.contains(scalingPresentName))
    return result
}

/// The two sides of an equality benchmark.
struct FieldsPair: Sendable {
    let lhs: HTTPFields
    let rhs: HTTPFields
}

/// Reverses the order of all non-`Cookie` fields, leaving every `Cookie` field in its original slot.
///
/// Two `HTTPFields` are equal regardless of the order of their differently named fields, but *not*
/// regardless of the order of the fields sharing one name. So only the fields with a unique name may
/// be permuted here; permuting the cookies would produce a value that is unequal rather than one
/// that is equal but differently ordered.
private func reorderingUniqueNames(_ fields: [HTTPField]) -> [HTTPField] {
    var reversed = fields.filter { $0.name != .cookie }.reversed().makeIterator()
    return fields.map { $0.name == .cookie ? $0 : reversed.next()! }
}

/// How far a locally displaced field moves. A small constant rather than a fraction of the list, so
/// that the same absolute edit is made at every size and the curve over N shows how equality scales
/// when the two lists are out of step by a bounded amount.
private let localDisplacementDistance = 3

/// Moves the first field a few slots later, leaving every other field where it was.
///
/// This is the realistic way two equal field lists come to be ordered differently: a proxy or a
/// second encoder emits one header at a slightly different point in the list. `reorderingUniqueNames`
/// is the opposite extreme, and the two bracket what equality has to cope with.
///
/// The field that moves has a name no other field in any of these lists shares, and it only jumps
/// over fields with other names, so the relative order of same-named fields is untouched and the
/// result is still equal to the input. Because the lists are nested, the fields involved are the same
/// at every size.
private func displacingOneField(_ fields: [HTTPField]) -> [HTTPField] {
    precondition(fields.count > localDisplacementDistance, "list too short to displace a field within")
    var fields = fields
    let field = fields.removeFirst()
    fields.insert(field, at: localDisplacementDistance)
    return fields
}

/// The position of the one field that differs between the two sides of a "late mismatch" pair: 80%
/// into the list, so that the leading 80% is identical.
private func lateMismatchIndex(_ count: Int) -> Int {
    count * 4 / 5
}

/// Changes the value of the field 80% into the list, leaving everything else alone.
private func withLateMismatch(_ fields: [HTTPField]) -> [HTTPField] {
    var fields = fields
    let index = lateMismatchIndex(fields.count)
    let field = fields[index]
    fields[index] = HTTPField(name: field.name, value: field.value + "-mismatch")
    return fields
}

// MARK: - Cases

/// Everything the benchmarks need for one field count, precomputed so that no fixture construction
/// is ever measured.
struct ScalingCase: Sendable {
    /// The number of fields, i.e. the N the benchmark names refer to.
    let n: Int
    /// How many of the `n` fields are `Cookie` fields, i.e. how many of them share a single name.
    let cookieCount: Int
    /// The fields as a decoder would hand them over.
    let fields: [HTTPField]
    /// A prebuilt value for the read-only benchmarks.
    let readFields: HTTPFields

    /// Equal, and appended in the same order.
    let equalSameOrder: FieldsPair
    /// Equal, but with the uniquely named fields appended in the opposite order.
    let equalDifferentOrder: FieldsPair
    /// Equal, but with one field appended a few slots away from where the other side has it. The
    /// number of displaced fields does not grow with `n`, so an equality that only pays for the
    /// fields that are actually out of step stays near-linear over this pair while
    /// `equalDifferentOrder` does not.
    let equalLocallyDisplaced: FieldsPair
    /// Unequal: the leading 80% is identical and in the same order, the field at 80% differs.
    ///
    /// Note what this does and does not pin down. It guarantees the shape — two field lists that
    /// differ in exactly one field, late in the list — which is the realistic way an inequality
    /// shows up. It does *not* guarantee that only 80% of the comparison work happens before the
    /// difference is found: the order in which `==` looks at fields is not part of its contract, so
    /// how much of the list it gets through first is not something a benchmark can fix.
    let mismatchSameOrder: FieldsPair
    /// Unequal in the same single field as `mismatchSameOrder`, with the uniquely named fields
    /// appended in the opposite order. The same caveat applies.
    let mismatchDifferentOrder: FieldsPair

    init(_ fields: [HTTPField]) {
        self.n = fields.count
        self.cookieCount = fields.filter { $0.name == .cookie }.count
        self.fields = fields
        self.readFields = makeFields(fields)

        let mismatched = withLateMismatch(fields)
        self.equalSameOrder = FieldsPair(lhs: makeFields(fields), rhs: makeFields(fields))
        self.equalDifferentOrder = FieldsPair(
            lhs: makeFields(fields),
            rhs: makeFields(reorderingUniqueNames(fields))
        )
        self.equalLocallyDisplaced = FieldsPair(
            lhs: makeFields(fields),
            rhs: makeFields(displacingOneField(fields))
        )
        self.mismatchSameOrder = FieldsPair(lhs: makeFields(fields), rhs: makeFields(mismatched))
        self.mismatchDifferentOrder = FieldsPair(
            lhs: makeFields(fields),
            rhs: makeFields(reorderingUniqueNames(mismatched))
        )
    }
}

let scalingCases: [ScalingCase] = [
    ScalingCase(scalingFields8),
    ScalingCase(scalingFields16),
    ScalingCase(scalingFields32),
    ScalingCase(scalingFields64),
    ScalingCase(scalingFields128),
]

/// A name that is present in every field list, for the lookup and mutation benchmarks.
let scalingPresentName: HTTPField.Name = .userAgent

/// A name that is present in no field list, for the failing lookup and the insertion benchmarks.
let scalingAbsentName: HTTPField.Name = .transferEncoding

/// Asserts that the fixtures mean what their names claim.
///
/// A fixture that is silently equal when it should be unequal, or that turns out to be a copy of the
/// value it is compared against, produces a plausible-looking but meaningless curve, so this runs on
/// every benchmark invocation rather than being a one-off check.
func validateScalingFixtures() {
    let expectedSizes = [8, 16, 32, 64, 128]
    precondition(scalingCases.map(\.n) == expectedSizes, "unexpected field counts")

    for (smaller, larger) in zip(scalingCases, scalingCases.dropFirst()) {
        precondition(Array(larger.fields.prefix(smaller.n)) == smaller.fields, "N=\(larger.n) is not nested")
    }

    for scalingCase in scalingCases {
        let n = scalingCase.n
        precondition(scalingCase.readFields.count == n, "N=\(n): wrong field count")
        precondition(scalingCase.readFields.contains(scalingPresentName), "N=\(n): missing present name")
        precondition(!scalingCase.readFields.contains(scalingAbsentName), "N=\(n): absent name is present")
        precondition(scalingCase.readFields[values: .cookie].count == scalingCase.cookieCount, "N=\(n): cookie count")

        let pairs = [
            ("equal, same order", scalingCase.equalSameOrder, true),
            ("equal, different order", scalingCase.equalDifferentOrder, true),
            ("equal, locally displaced", scalingCase.equalLocallyDisplaced, true),
            ("differs at 80%, same order", scalingCase.mismatchSameOrder, false),
            ("differs at 80%, different order", scalingCase.mismatchDifferentOrder, false),
        ]
        for (description, pair, expected) in pairs {
            precondition(pair.lhs.count == n && pair.rhs.count == n, "N=\(n): \(description) has wrong field count")
            precondition((pair.lhs == pair.rhs) == expected, "N=\(n): \(description) is not \(expected)")
        }

        // A pair that is meant to be equal but differently ordered is worthless if it turns out to
        // be in the same order after all, because then it measures the same thing as the same-order
        // pair while claiming to measure the reordered case.
        let reorderedPairs = [
            ("equal, different order", scalingCase.equalDifferentOrder),
            ("equal, locally displaced", scalingCase.equalLocallyDisplaced),
        ]
        for (description, pair) in reorderedPairs {
            precondition(
                n < 2 || !Array(pair.lhs).elementsEqual(pair.rhs),
                "N=\(n): \(description) is actually in the same order"
            )
        }

        // The locally displaced pair only measures what it claims to if exactly one field moved, and
        // by the expected distance. Anything else and the "bounded displacement" curve is not that.
        let displaced = scalingCase.equalLocallyDisplaced
        let movedPositions = zip(Array(displaced.lhs), Array(displaced.rhs)).enumerated()
            .filter { $0.element.0 != $0.element.1 }
            .map(\.offset)
        precondition(
            movedPositions == Array(0...localDisplacementDistance),
            "N=\(n): locally displaced pair disturbs \(movedPositions.count) positions, not \(localDisplacementDistance + 1)"
        )
    }
}
