import Foundation
import LlmTesterReport

do {
    let options = try LlmTesterOptions.parse(Array(CommandLine.arguments.dropFirst()))
    let manifest = try LlmTesterRunner.loadManifest(at: options.manifestPath)
    let providerPreference = LlmTesterRunner.hostTextProviderPreference(for: options.provider)
    let client = LlmTesterRunner.makeClient(preference: providerPreference)
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
