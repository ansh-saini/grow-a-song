import Foundation
import GrowCore
import HuggingFace
import MLX
import MLXGuidedGeneration
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

struct ComposeResult: Sendable {
    var spec: SongSpec
    /// False when the default/fallback spec was used.
    var fromModel: Bool
    /// True when JSON-schema constrained decoding produced the answer.
    var guided: Bool
    var seconds: Double
    var raw: String
    var error: String?
}

/// Runs Gemma 3 1B on device and asks it to compose today's song.
/// Output is constrained to SongSpec's JSON schema, with a parse fallback.
actor GemmaComposer {
    static let configuration = LLMRegistry.gemma3_1B_qat_4bit
    static var modelName: String { "Gemma 3 1B (QAT 4-bit)" }

    private var container: ModelContainer?
    private var loading: Task<ModelContainer, Error>?

    var isLoaded: Bool { container != nil }

    /// Downloads on first use (~0.8 GB), then loads from the on-device cache.
    /// Concurrent callers share one load.
    func load(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        if container != nil { return }
        if let loading {
            container = try await loading.value
            return
        }
        MLX.Memory.cacheLimit = 64 * 1024 * 1024
        Self.useDurableModelStorage()
        let task = Task {
            try await #huggingFaceLoadModelContainer(
                configuration: Self.configuration,
                progressHandler: { p in progress(p.fractionCompleted) })
        }
        loading = task
        defer { loading = nil }
        container = try await task.value
    }

    /// iOS deletes Library/Caches under storage pressure, which wiped the downloaded model
    /// on a real phone and forced a fresh 0.8 GB download. Application Support is never purged.
    /// Excluded from iCloud backup since it can always be downloaded again.
    static func useDurableModelStorage() {
        #if os(iOS)
        guard var dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        dir.appendPathComponent("huggingface/hub", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        setenv("HF_HUB_CACHE", dir.path, 1)
        #endif
    }

    /// Frees GPU memory so the audio engine has the phone to itself.
    func unload() {
        guard loading == nil else { return }
        container = nil
        MLX.Memory.clearCache()
    }

    func compose(_ ctx: ComposerContext) async -> ComposeResult {
        let start = Date()
        let prompt = PromptBuilder.composePrompt(ctx)
        do {
            try await load()
            guard let container else { throw ComposerError.notLoaded }

            var guidedError: String?
            do {
                let raw = try await guidedJSON(container: container, prompt: prompt)
                if var spec = SongSpec.parse(raw) {
                    spec.bpm = TempoGuard.bpm(spec.bpm, activity: ctx.activity)
                    return ComposeResult(spec: spec, fromModel: true, guided: true, seconds: Date().timeIntervalSince(start), raw: raw)
                }
                guidedError = "guided output did not parse: \(raw.prefix(200))"
            } catch {
                guidedError = "guided failed: \(error)"
            }

            // Unconstrained fallback: ask nicely and parse whatever comes back.
            let session = ChatSession(
                container, instructions: PromptBuilder.system,
                generateParameters: GenerateParameters(maxTokens: 360, temperature: 0.7))
            let raw = try await withError { try await session.respond(to: prompt + "\n\nReply with only the JSON object.") }
            if var spec = SongSpec.parse(raw) {
                spec.bpm = TempoGuard.bpm(spec.bpm, activity: ctx.activity)
                return ComposeResult(spec: spec, fromModel: true, guided: false, seconds: Date().timeIntervalSince(start), raw: raw, error: guidedError)
            }
            return ComposeResult(
                spec: .default, fromModel: false, guided: false, seconds: Date().timeIntervalSince(start),
                raw: raw, error: "Model reply had no JSON")
        } catch {
            return ComposeResult(
                spec: .default, fromModel: false, guided: false, seconds: Date().timeIntervalSince(start),
                raw: "", error: String(describing: error))
        }
    }

    func fieldNote(prompt: String) async -> String? {
        do {
            try await load()
            guard let container else { return nil }
            let session = ChatSession(
                container,
                instructions: "You write short, plain field notes for a walking and running journal.",
                generateParameters: GenerateParameters(maxTokens: 90, temperature: 0.8))
            let text = PromptBuilder.cleanFieldNote(try await withError { try await session.respond(to: prompt) })
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }

    private func guidedJSON(container: ModelContainer, prompt: String) async throws -> String {
        try await container.perform { context in
            let tokenizer = context.tokenizer
            let vocab = TokenizerVocabExtractor.extractForGrammar(from: tokenizer)
            let grammarTokenizer = try GrammarTokenizer(
                vocab: vocab.vocab, vocabType: vocab.vocabType,
                eosTokenId: Int32(tokenizer.eosTokenId ?? 0))
            let constraint = try GrammarConstraint(
                tokenizer: grammarTokenizer, jsonSchema: SongSpec.jsonSchema,
                fastForward: true, hostTokenizer: tokenizer)
            let input = try await context.processor.prepare(
                input: UserInput(chat: [.system(PromptBuilder.system), .user(prompt)]))
            let bias = WhitespaceTokenBias.compute(tokenizer: tokenizer)
            let closing = ClosingTokenBias.compute(tokenizer: tokenizer, eosTokenId: tokenizer.eosTokenId)
            var output = ""
            do {
                // withError turns MLX failures (e.g. GPU work denied in background) into Swift errors
                // instead of the default fatalError.
                try withError {
                    try GuidedGenerationLoop.run(
                        input: input, context: context, constraint: constraint,
                        maxTokens: 400, vocabSize: grammarTokenizer.vocabSize,
                        closingBias: closing, whitespaceBias: bias.bias, whitespaceTokenIDs: bias.tokenIDs
                    ) { delta in
                        output += delta
                        return true
                    }
                }
            } catch {
                throw ComposerError.guided("\(error) after: \(output.suffix(300))")
            }
            return output
        }
    }
}

enum ComposerError: Error {
    case notLoaded
    case guided(String)
}
