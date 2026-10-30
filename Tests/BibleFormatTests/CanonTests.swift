import BibleFormat
import Testing

@Suite struct CanonTests {
    @Test func definesEightySixBooksAndShipsSixtySix() {
        #expect(Canon.defined.count == 86)
        #expect(Canon.shipped.count == 66)
        #expect(Canon.shipped.allSatisfy { $0.testament != .apocrypha })
        #expect(Book.allCases.count == 86)
    }

    @Test func ordersFollowCaseOrder() {
        #expect(Book.allCases.map { Canon.info($0).order } == Array(1...86))
        #expect(Canon.defined.map(\.id) == Book.allCases)
        #expect(Book.allCases == Book.allCases.sorted())
    }

    @Test func idsAreUniqueUSFMCodes() {
        let ids = Book.allCases.map(\.rawValue)
        #expect(Set(ids).count == 86)
        #expect(ids.allSatisfy { $0.count == 3 && $0 == $0.uppercased() })
    }

    @Test func noLookupNameCollidesAcrossBooks() {
        var owner: [String: Book] = [:]
        var collisions: [String] = []
        for info in Canon.defined {
            for name in info.lookupNames {
                let key = name.lowercased()
                if let other = owner[key], other != info.id {
                    collisions.append("\(name): \(other.rawValue) and \(info.id.rawValue)")
                }
                owner[key] = info.id
            }
        }
        #expect(collisions.isEmpty)
    }

    @Test func everyLookupNameFindsItsBook() {
        for info in Canon.defined {
            for name in info.lookupNames {
                #expect(Canon.book(matching: name) == info.id, "\(name)")
                #expect(Canon.book(matching: name.uppercased()) == info.id, "\(name)")
            }
        }
    }

    @Test(arguments: [
        ("1 Sam", Book.firstSamuel),
        ("song of songs", .songOfSolomon),
        ("GEN", .genesis),
        ("gen", .genesis),
        ("Matt", .matthew),
        ("Phlm", .philemon),
        ("Psalm 151", .psalm151),
        ("psalm", .psalms),
    ])
    func findsBooksByAlias(alias: String, book: Book) {
        #expect(Canon.book(matching: alias) == book)
    }

    @Test func rejectsUnknownNames() {
        #expect(Canon.book(matching: "Hezekiah") == nil)
        #expect(Canon.book(matching: "") == nil)
    }

    @Test func shippedChapterCountsMatchTheEngScheme() throws {
        let eng = try Versification.counts(for: .eng)
        #expect(eng.books == Canon.shipped.map(\.id))
        for info in Canon.shipped {
            #expect(eng.chapters(in: info.id) == info.chapters, "\(info.id.rawValue)")
        }
    }

    @Test(arguments: [
        (Section.law, Book.genesis, Book.deuteronomy),
        (.history, .joshua, .esther),
        (.wisdomAndPoetry, .job, .songOfSolomon),
        (.majorProphets, .isaiah, .daniel),
        (.minorProphets, .hosea, .malachi),
        (.gospelsAndActs, .matthew, .acts),
        (.paulsLetters, .romans, .philemon),
        (.generalLetters, .hebrews, .jude),
        (.prophecy, .revelation, .revelation),
        (.apocrypha, .tobit, .psalmsOfSolomon),
    ])
    func sectionsAreContiguousRuns(section: Section, first: Book, last: Book) {
        let books = Canon.defined.filter { $0.section == section }.map(\.id)
        let expected = Book.allCases.filter { $0 >= first && $0 <= last }
        #expect(books == expected)
    }

    @Test func sectionsAgreeWithTestaments() {
        let oldTestament: Set<Section> = [.law, .history, .wisdomAndPoetry, .majorProphets, .minorProphets]
        for info in Canon.defined {
            switch info.testament {
            case .oldTestament: #expect(oldTestament.contains(info.section), "\(info.id.rawValue)")
            case .newTestament: #expect(!oldTestament.contains(info.section) && info.section != .apocrypha)
            case .apocrypha: #expect(info.section == .apocrypha)
            }
        }
    }
}
