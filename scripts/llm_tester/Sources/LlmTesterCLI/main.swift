import Foundation
import LlmTesterReport

do {
    let options = try LlmTesterOptions.parse(Array(CommandLine.arguments.dropFirst()))
    if let snapshotPath = options.snapshotPath {
        let currentSummary = try LlmTesterRunner.loadSnapshotSummary(at: snapshotPath)
        let summary: E2ESnapshotRunSummary
        if let baselinePath = options.baselinePath {
            let baselineSummary = try LlmTesterRunner.loadSnapshotSummary(at: baselinePath)
            summary = E2ESnapshotComparator.compare(current: currentSummary, baseline: baselineSummary)
        } else {
            summary = currentSummary
        }
        try E2ESnapshotReport.write(summary: summary, to: options.outputPath)
        print("E2E snapshot report wrote \(options.outputPath)")
        print("Scenarios: \(summary.total) succeeded=\(summary.succeeded) failed=\(summary.failed)")
        if summary.failed > 0 {
            Foundation.exit(1)
        }
        Foundation.exit(0)
    }

    guard let manifestPath = options.manifestPath else {
        throw LlmTesterError.missingManifest
    }
    let manifest = try LlmTesterRunner.loadManifest(at: manifestPath)
    let providerPreference = LlmTesterRunner.hostTextProviderPreference(for: options.provider)
    let client = try LlmTesterRunner.makeClient(preference: providerPreference)
    let summary = await LlmTesterRunner.run(
        manifest: manifest,
        client: client,
        providerPreference: providerPreference
    )
    try HtmlReport.write(summary: summary, to: options.outputPath)
    print("LLM tester wrote \(options.outputPath)")
    print("Scenarios: \(summary.total) succeeded=\(summary.succeeded) failed=\(summary.failed)")
    if summary.failed > 0 {
        Foundation.exit(1)
    }
} catch LlmTesterError.missingManifest {
    LlmTesterOptions.printUsage()
    Foundation.exit(2)
} catch LlmTesterError.invalidArguments(let message) {
    fputs("Error: \(message)\n", stderr)
    LlmTesterOptions.printUsage()
    Foundation.exit(2)
} catch {
    fputs("Error: \(error)\n", stderr)
    Foundation.exit(1)
}
