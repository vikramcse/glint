import Testing

@testable import GlintEmbedding

@Suite("EG2Processor truncation")
struct EG2ProcessorTruncationTests {
    let media: Set<Int32> = [100, 101]
    let eos = Int32(EG2Processor.eosToken)

    @Test func shortSequenceIsOnlyClosed() throws {
        #expect(try EG2Processor.closed([2, 5, 6], maxTokens: 8, mediaTokens: media) == [2, 5, 6, eos])
    }

    @Test func trailingTextIsTrimmedToFitEos() throws {
        let ids: [Int32] = [2, 100, 101, 7, 8, 9, 10, 11]
        let closed = try EG2Processor.closed(ids, maxTokens: 6, mediaTokens: media)
        #expect(closed == [2, 100, 101, 7, 8, eos])
    }

    @Test func fullLengthSequenceStaysWithinLimit() throws {
        let closed = try EG2Processor.closed([2, 3, 4, 5], maxTokens: 4, mediaTokens: media)
        #expect(closed == [2, 3, 4, eos])
    }

    /// The media span's closing token sits at the last index before <eos>; trimming would cut it.
    @Test func mediaInTheEosSlotIsNotCut() {
        let ids: [Int32] = [2, 3, 100, 101, 7]
        #expect(throws: EG2Error.inputTooLong(tokens: 5)) {
            try EG2Processor.closed(ids, maxTokens: 4, mediaTokens: media)
        }
    }

    @Test func mediaJustBeforeTheEosSlotIsKept() throws {
        let ids: [Int32] = [2, 100, 101, 7, 8]
        #expect(try EG2Processor.closed(ids, maxTokens: 4, mediaTokens: media) == [2, 100, 101, eos])
    }
}
