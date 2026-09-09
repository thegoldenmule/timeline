import Foundation
import Testing

@testable import TimelineUI

/// The search field's ranking rules, stated as comparisons rather than magic totals so the weights can
/// be retuned without rewriting the suite.
@Suite("Fuzzy search")
struct FuzzySearchTests {
    private func score(_ query: String, _ candidate: String) -> Int? { FuzzyMatch.score(query, in: candidate) }

    @Test func everyQueryCharacterMustMatchInOrder() {
        #expect(score("cam", "cam.mov") != nil)
        #expect(score("cmv", "cam.mov") != nil, "a subsequence need not be contiguous")
        #expect(score("mac", "cam.mov") == nil, "out of order")
        #expect(score("camx", "cam.mov") == nil, "an unmatched character fails the whole match")
        #expect(score("cam.mov!", "cam.mov") == nil, "a query longer than the candidate cannot match")
    }

    @Test func aPrefixMatchOutranksAMidWordMatch() throws {
        let prefix = try #require(score("cam", "cam.mov"))
        let interior = try #require(score("cam", "webcam.mov"))
        #expect(prefix > interior)
    }

    @Test func contiguousMatchesOutrankScatteredOnes() throws {
        let run = try #require(score("abc", "abcxx"))
        let scattered = try #require(score("abc", "axbxc"))
        #expect(run > scattered)
    }

    @Test func wordBoundariesAreWorthMoreThanInteriorCharacters() throws {
        // Same length, same two characters: the one that starts words wins.
        let boundaries = try #require(score("bm", "band mix"))
        let interior = try #require(score("bm", "abmxxxxx"))
        #expect(boundaries > interior)
        // A camel-case hump starts a word too.
        let camel = try #require(score("bm", "bandMix"))
        let flat = try #require(score("bm", "bandmix"))
        #expect(camel > flat)
    }

    @Test func theShorterNameWinsATie() throws {
        let short = try #require(score("cam", "cam.mov"))
        let long = try #require(score("cam", "cam.mov.backup"))
        #expect(short > long)
    }

    @Test func matchingIgnoresCaseAndDiacritics() {
        #expect(score("cafe", "Café.mov") == score("CAFE", "cafe.mov"))
        #expect(score("CAFÉ", "cafe.mov") != nil)
        #expect(score("cam", "CAM.MOV") != nil)
    }

    @Test func anEmptyQueryMatchesEverythingWithScoreZero() {
        #expect(score("", "cam.mov") == 0)
        #expect(score("", "") == 0)
        #expect(score("cam", "") == nil)
    }
}
