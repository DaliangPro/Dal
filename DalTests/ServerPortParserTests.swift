import Foundation
import XCTest
@testable import Dal

final class ServerPortParserTests: XCTestCase {
    func testPortMarkerSplitAcrossTwoChunks() {
        assertPort(chunks: ["PO", "RT:54321\n"], expected: 54321)
    }

    func testPortMarkerSplitAcrossThreeChunks() {
        assertPort(chunks: ["P", "ORT", ":54321\n"], expected: 54321)
    }

    func testPortMarkerSplitAcrossFourChunks() {
        assertPort(chunks: ["P", "OR", "T:54", "321\n"], expected: 54321)
    }

    func testParserFindsPortAfterMultipleLogLines() {
        var parser = PortLineParser()

        let port = parser.feed(Data("loading\nmodel ready\nPORT:61234\nnext\n".utf8))

        XCTAssertEqual(port, 61234)
    }

    func testParserIgnoresMalformedAndOutOfRangePorts() {
        var parser = PortLineParser()

        XCTAssertNil(
            parser.feed(
                Data(
                    "PORT:\nPORT:0\nPORT:-1\nPORT:65536\nPORT:12x\nPORT:123 extra\n".utf8
                )
            )
        )
        XCTAssertEqual(parser.feed(Data("PORT:12345\n".utf8)), 12345)
    }

    func testParserWaitsForNewlineBeforeResolvingPort() {
        var parser = PortLineParser()

        XCTAssertNil(parser.feed(Data("PORT:45678".utf8)))
        XCTAssertEqual(parser.feed(Data("\n".utf8)), 45678)
    }

    func testParserAcceptsBoundaryPortsAndCRLF() {
        var minimumParser = PortLineParser()
        var maximumParser = PortLineParser()

        XCTAssertEqual(minimumParser.feed(Data("PORT:1\r\n".utf8)), 1)
        XCTAssertEqual(maximumParser.feed(Data("PORT:65535\n".utf8)), 65535)
    }

    func testPortReaderRemovesReadabilityHandlerAfterSuccess() async throws {
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: Data("PORT:45678\n".utf8))

        let port = await ServerPortReader.discoverPort(
            from: pipe,
            timeout: .seconds(1)
        )

        XCTAssertEqual(port, 45678)
        XCTAssertNil(pipe.fileHandleForReading.readabilityHandler)
    }

    func testPortReaderRemovesReadabilityHandlerAtEOF() async throws {
        let pipe = Pipe()
        try pipe.fileHandleForWriting.close()

        let port = await ServerPortReader.discoverPort(
            from: pipe,
            timeout: .seconds(1)
        )

        XCTAssertNil(port)
        XCTAssertNil(pipe.fileHandleForReading.readabilityHandler)
    }

    func testPortReaderRemovesReadabilityHandlerAfterTimeout() async {
        let pipe = Pipe()

        let port = await ServerPortReader.discoverPort(
            from: pipe,
            timeout: .milliseconds(50)
        )

        XCTAssertNil(port)
        XCTAssertNil(pipe.fileHandleForReading.readabilityHandler)
    }

    private func assertPort(chunks: [String], expected: Int) {
        var parser = PortLineParser()
        for chunk in chunks.dropLast() {
            XCTAssertNil(parser.feed(Data(chunk.utf8)))
        }
        XCTAssertEqual(parser.feed(Data(chunks.last!.utf8)), expected)
    }
}
