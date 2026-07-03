import Foundation

public enum E2ESnapshotReport {
    public static func write(summary: E2ESnapshotRunSummary, to outputPath: String) throws {
        try render(summary: summary).write(toFile: outputPath, atomically: true, encoding: .utf8)
    }

    public static func render(summary: E2ESnapshotRunSummary) -> String {
        let scenarios = sortedScenarios(summary.scenarios)
        var html: [String] = []
        html.append("<!DOCTYPE html>")
        html.append("<html lang=\"en\">")
        html.append("<head>")
        html.append("<meta charset=\"utf-8\">")
        html.append("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">")
        html.append("<title>E2E Snapshot Report</title>")
        html.append("<style>")
        html.append(style)
        html.append("</style>")
        html.append("</head>")
        html.append("<body>")
        html.append("<main>")
        html.append("<header class=\"report-header\">")
        html.append("<div>")
        html.append("<h1>E2E Snapshot Report</h1>")
        html.append("<p class=\"meta\">\(escape(summary.suiteName)) · Baseline \(escape(summary.baselineName)) · \(escape(summary.generatedAt))</p>")
        html.append("</div>")
        html.append("<div class=\"report-actions\">")
        html.append("<button type=\"button\" class=\"copy-btn copy-all-btn\" data-default-label=\"Copy All\">Copy All</button>")
        if let firstFailure = firstFailureAnchor(in: scenarios) {
            html.append("<a class=\"jump\" href=\"#\(escape(firstFailure))\">Jump to first failure</a>")
        }
        html.append("</div>")
        html.append("</header>")
        html.append(renderCopySource(text: allCopyText(for: scenarios), cssClass: "copy-all-source"))
        html.append("<section class=\"metrics\">")
        html.append(metric("Scenarios", "\(summary.total)"))
        html.append(metric("Succeeded", "\(summary.succeeded)", cssClass: "ok"))
        html.append(metric("Failed", "\(summary.failed)", cssClass: "failed"))
        html.append("</section>")
        html.append("<div class=\"layout\">")
        html.append(renderFailureRail(scenarios))
        html.append("<section class=\"content\">")
        for scenario in scenarios {
            html.append(renderScenario(scenario))
        }
        html.append("</section>")
        html.append("</div>")
        html.append("</main>")
        html.append(renderCopyScript())
        html.append("</body>")
        html.append("</html>")
        return html.joined(separator: "\n")
    }

    public static func sortedScenarios(_ scenarios: [E2ESnapshotScenarioResult]) -> [E2ESnapshotScenarioResult] {
        scenarios.sorted { lhs, rhs in
            let left = statusSortOrder(lhs.status)
            let right = statusSortOrder(rhs.status)
            if left != right { return left < right }
            return lhs.id < rhs.id
        }
    }

    public static func statusSortOrder(_ status: E2ESnapshotStatus) -> Int {
        switch status {
        case .error: return 0
        case .failed: return 1
        case .changed: return 2
        case .skipped: return 3
        case .ok: return 4
        }
    }

    public static func scenarioAnchorId(for scenarioId: String) -> String {
        "scenario-\(sanitizeAnchorPart(scenarioId))"
    }

    public static func stepAnchorId(scenarioId: String, stepId: String) -> String {
        "step-\(sanitizeAnchorPart(scenarioId))-\(sanitizeAnchorPart(stepId))"
    }

    private static func firstFailureAnchor(in scenarios: [E2ESnapshotScenarioResult]) -> String? {
        for scenario in scenarios {
            if let step = scenario.firstProblemStep {
                return stepAnchorId(scenarioId: scenario.id, stepId: step.id)
            }
            if !scenario.status.isSuccessful {
                return scenarioAnchorId(for: scenario.id)
            }
        }
        return nil
    }

    private static func renderFailureRail(_ scenarios: [E2ESnapshotScenarioResult]) -> String {
        var parts: [String] = []
        parts.append("<nav class=\"rail\" aria-label=\"Snapshot failures and scenarios\">")
        parts.append("<h2>Flow Index</h2>")
        parts.append("<ol>")
        for scenario in scenarios {
            let scenarioAnchor = scenarioAnchorId(for: scenario.id)
            let target = scenario.firstProblemStep.map { stepAnchorId(scenarioId: scenario.id, stepId: $0.id) } ?? scenarioAnchor
            parts.append("<li class=\"rail-item \(escape(scenario.status.rawValue))\">")
            parts.append("<a href=\"#\(escape(target))\">")
            parts.append("<span>\(escape(scenario.id))</span>")
            parts.append("<strong>\(escape(scenario.status.rawValue))</strong>")
            parts.append("</a>")
            parts.append("</li>")
        }
        parts.append("</ol>")
        parts.append("</nav>")
        return parts.joined(separator: "\n")
    }

    private static func renderScenario(_ scenario: E2ESnapshotScenarioResult) -> String {
        var parts: [String] = []
        parts.append("<article class=\"scenario \(escape(scenario.status.rawValue))\" id=\"\(escape(scenarioAnchorId(for: scenario.id)))\">")
        parts.append("<header class=\"scenario-header\">")
        parts.append("<div>")
        parts.append("<h2>\(escape(scenario.label))</h2>")
        parts.append("<p class=\"description\">\(escape(scenario.description))</p>")
        parts.append("<p class=\"meta\">\(escape(scenario.id)) · \(scenario.durationMs) ms</p>")
        if !scenario.qualities.isEmpty {
            parts.append("<div class=\"qualities\">\(scenario.qualities.map { "<span>\(escape($0))</span>" }.joined())</div>")
        }
        parts.append("</div>")
        parts.append("<div class=\"scenario-actions\">")
        parts.append("<button type=\"button\" class=\"copy-btn\" data-default-label=\"Copy\">Copy</button>")
        parts.append("<span class=\"badge \(escape(scenario.status.rawValue))\">\(escape(scenario.status.rawValue))</span>")
        parts.append("</div>")
        parts.append("</header>")
        parts.append(renderCopySource(text: scenarioCopyText(for: scenario)))
        parts.append(renderFlowchart(scenario))
        for step in scenario.steps {
            parts.append(renderStep(step, scenarioId: scenario.id))
        }
        for artifact in scenario.artifacts {
            parts.append(renderArtifact(artifact, titlePrefix: "Scenario Artifact"))
        }
        parts.append("</article>")
        return parts.joined(separator: "\n")
    }

    private static func renderFlowchart(_ scenario: E2ESnapshotScenarioResult) -> String {
        var parts: [String] = []
        parts.append("<section class=\"flowchart\" aria-label=\"Scenario flowchart\">")
        for (index, step) in scenario.steps.enumerated() {
            if index > 0 {
                parts.append("<span class=\"connector\" aria-hidden=\"true\">→</span>")
            }
            let anchor = stepAnchorId(scenarioId: scenario.id, stepId: step.id)
            parts.append("<a class=\"flow-node \(escape(step.status.rawValue))\" href=\"#\(escape(anchor))\">")
            parts.append("<span class=\"node-kind\">\(escape(step.kind))</span>")
            parts.append("<strong>\(escape(step.label))</strong>")
            parts.append("<em>\(escape(step.status.rawValue))</em>")
            parts.append("</a>")
        }
        parts.append("</section>")
        return parts.joined(separator: "\n")
    }

    private static func renderStep(_ step: E2ESnapshotStep, scenarioId: String) -> String {
        var parts: [String] = []
        let anchor = stepAnchorId(scenarioId: scenarioId, stepId: step.id)
        parts.append("<section class=\"step \(escape(step.status.rawValue))\" id=\"\(escape(anchor))\">")
        parts.append("<header class=\"step-header\">")
        parts.append("<div>")
        parts.append("<h3>\(escape(step.label))</h3>")
        parts.append("<p class=\"meta\">\(escape(step.id)) · \(escape(step.kind))</p>")
        parts.append("</div>")
        parts.append("<span class=\"badge \(escape(step.status.rawValue))\">\(escape(step.status.rawValue))</span>")
        parts.append("</header>")
        parts.append("<p>\(escape(step.summary))</p>")
        if let detail = step.detail, !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("<pre class=\"detail\"><code>\(escape(detail))</code></pre>")
        }
        if !step.assertions.isEmpty {
            parts.append("<div class=\"assertions\">")
            for assertion in step.assertions {
                parts.append(renderAssertion(assertion))
            }
            parts.append("</div>")
        }
        for artifact in step.artifacts {
            parts.append(renderArtifact(artifact, titlePrefix: "Step Artifact"))
        }
        parts.append("</section>")
        return parts.joined(separator: "\n")
    }

    private static func renderAssertion(_ assertion: E2ESnapshotAssertion) -> String {
        var parts: [String] = []
        parts.append("<div class=\"assertion \(escape(assertion.status.rawValue))\">")
        parts.append("<div class=\"assertion-title\"><strong>\(escape(assertion.label))</strong><span>\(escape(assertion.status.rawValue))</span></div>")
        parts.append("<p>\(escape(assertion.message))</p>")
        if assertion.expected != nil || assertion.actual != nil {
            parts.append("<div class=\"diff-grid\">")
            parts.append("<div class=\"copy-block\"><div class=\"copy-block-header\"><h4>Expected</h4><button type=\"button\" class=\"copy-btn copy-local-btn\" data-default-label=\"Copy\">Copy</button></div>\(renderCopySource(text: assertion.expected ?? ""))<pre><code>\(escape(assertion.expected ?? ""))</code></pre></div>")
            parts.append("<div class=\"copy-block\"><div class=\"copy-block-header\"><h4>Actual</h4><button type=\"button\" class=\"copy-btn copy-local-btn\" data-default-label=\"Copy\">Copy</button></div>\(renderCopySource(text: assertion.actual ?? ""))<pre><code>\(escape(assertion.actual ?? ""))</code></pre></div>")
            parts.append("</div>")
        }
        parts.append("</div>")
        return parts.joined(separator: "\n")
    }

    private static func renderArtifact(_ artifact: E2ESnapshotArtifact, titlePrefix: String) -> String {
        """
        <details class="artifact">
          <summary><span>\(escape(titlePrefix)): \(escape(artifact.label))</span><button type="button" class="copy-btn copy-local-btn" data-default-label="Copy">Copy</button></summary>
          \(renderCopySource(text: artifact.body))
          <pre><code class="language-\(escape(artifact.language))">\(escape(artifact.body))</code></pre>
        </details>
        """
    }

    public static func scenarioCopyText(for scenario: E2ESnapshotScenarioResult) -> String {
        var parts: [String] = [
            "--- Scenario: \(scenario.id) ---",
            "Label: \(scenario.label)",
            "Status: \(scenario.status.rawValue)",
            "Qualities: \(scenario.qualities.joined(separator: ", "))",
            "",
            scenario.description,
        ]
        for step in scenario.steps {
            parts.append("\n--- Step: \(step.id) ---")
            parts.append("Label: \(step.label)")
            parts.append("Kind: \(step.kind)")
            parts.append("Status: \(step.status.rawValue)")
            parts.append("Summary: \(step.summary)")
            if let detail = step.detail, !detail.isEmpty {
                parts.append("Detail:\n\(detail)")
            }
            for assertion in step.assertions {
                parts.append("\nAssertion: \(assertion.label) [\(assertion.status.rawValue)]")
                parts.append(assertion.message)
                if let expected = assertion.expected {
                    parts.append("Expected:\n\(expected)")
                }
                if let actual = assertion.actual {
                    parts.append("Actual:\n\(actual)")
                }
            }
            for artifact in step.artifacts {
                parts.append("\nArtifact: \(artifact.label) (\(artifact.language))")
                parts.append(artifact.body)
            }
        }
        for artifact in scenario.artifacts {
            parts.append("\nScenario Artifact: \(artifact.label) (\(artifact.language))")
            parts.append(artifact.body)
        }
        return parts.joined(separator: "\n")
    }

    public static func allCopyText(for scenarios: [E2ESnapshotScenarioResult]) -> String {
        sortedScenarios(scenarios).map(scenarioCopyText(for:)).joined(separator: "\n\n")
    }

    private static func jsonEmbed(_ text: String) -> String {
        guard let data = try? JSONEncoder().encode(text),
              let encoded = String(data: data, encoding: .utf8)
        else {
            return "\"\""
        }
        return encoded
    }

    private static func renderCopySource(text: String, cssClass: String = "copy-source") -> String {
        """
        <script type="application/json" class="\(cssClass)">\(jsonEmbed(text))</script>
        """
    }

    private static func renderCopyScript() -> String {
        """
        <script>
        (function () {
          function copyFromSource(button, source) {
            if (!source) return;
            const text = JSON.parse(source.textContent);
            const defaultLabel = button.dataset.defaultLabel || button.textContent;
            navigator.clipboard.writeText(text).then(function () {
              button.textContent = 'Copied!';
              button.classList.add('copied');
              setTimeout(function () {
                button.textContent = defaultLabel;
                button.classList.remove('copied');
              }, 2000);
            });
          }

          document.querySelectorAll('.copy-all-btn').forEach(function (button) {
            button.addEventListener('click', function () {
              copyFromSource(button, document.querySelector('.copy-all-source'));
            });
          });

          document.querySelectorAll('.scenario-header .copy-btn:not(.copy-all-btn)').forEach(function (button) {
            button.addEventListener('click', function () {
              const scenario = button.closest('.scenario');
              if (!scenario) return;
              copyFromSource(button, scenario.querySelector(':scope > .copy-source'));
            });
          });

          document.querySelectorAll('.copy-local-btn').forEach(function (button) {
            button.addEventListener('click', function (event) {
              event.preventDefault();
              event.stopPropagation();
              const container = button.closest('.artifact, .copy-block');
              if (!container) return;
              copyFromSource(button, container.querySelector('.copy-source'));
            });
          });
        })();
        </script>
        """
    }

    private static func metric(_ label: String, _ value: String, cssClass: String? = nil) -> String {
        let classAttr = cssClass.map { " \($0)" } ?? ""
        return "<div class=\"metric\(classAttr)\"><span>\(escape(label))</span><strong>\(escape(value))</strong></div>"
    }

    private static func sanitizeAnchorPart(_ raw: String) -> String {
        String(raw.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" {
                return Character(scalar)
            }
            return "-"
        })
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static let style = """
    :root { color-scheme: dark; --bg: #0b0d10; --panel: #15191f; --soft: #1d232b; --border: #303844; --text: #edf2f7; --muted: #9aa7b5; --ok: #35c46a; --changed: #d9a441; --failed: #ff6b5f; --error: #ff4d7a; --skipped: #8f9bab; --link: #80b7ff; }
    body { margin: 0; background: var(--bg); color: var(--text); font-family: ui-sans-serif, system-ui, -apple-system, sans-serif; line-height: 1.5; }
    main { max-width: 1440px; margin: 0 auto; padding: 24px; }
    .report-header { display: flex; justify-content: space-between; gap: 16px; align-items: flex-start; margin-bottom: 20px; }
    h1, h2, h3, h4, p { margin-top: 0; }
    .meta, .description { color: var(--muted); }
    .report-actions, .scenario-actions { display: flex; gap: 10px; align-items: center; }
    .jump { border: 1px solid var(--border); background: var(--soft); color: var(--link); border-radius: 8px; padding: 8px 12px; text-decoration: none; font-weight: 700; }
    .copy-btn { border: 1px solid var(--border); background: #010409; color: var(--muted); border-radius: 6px; padding: 4px 10px; font-size: 12px; font-weight: 700; cursor: pointer; }
    .copy-btn:hover { color: var(--text); border-color: #484f58; }
    .copy-btn.copied { color: var(--ok); border-color: rgba(53, 196, 106, 0.45); }
    .copy-source, .copy-all-source { display: none; }
    .metrics { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 12px; margin-bottom: 24px; }
    .metric { background: var(--panel); border: 1px solid var(--border); border-radius: 8px; padding: 14px; }
    .metric span { display: block; color: var(--muted); font-size: 12px; text-transform: uppercase; }
    .metric strong { display: block; font-size: 28px; }
    .metric.ok strong { color: var(--ok); }
    .metric.failed strong { color: var(--failed); }
    .layout { display: grid; grid-template-columns: 280px minmax(0, 1fr); gap: 24px; align-items: start; }
    .rail { position: sticky; top: 24px; max-height: calc(100vh - 48px); overflow: auto; border-right: 1px solid var(--border); padding-right: 16px; }
    .rail h2 { font-size: 13px; text-transform: uppercase; color: var(--muted); }
    .rail ol { list-style: none; margin: 0; padding: 0; }
    .rail-item a { display: flex; justify-content: space-between; gap: 8px; color: var(--text); text-decoration: none; padding: 8px 10px; border-radius: 8px; }
    .rail-item a:hover { background: var(--soft); }
    .rail-item strong { color: var(--muted); font-size: 11px; text-transform: uppercase; }
    .rail-item.failed strong, .rail-item.error strong { color: var(--failed); }
    .scenario { background: var(--panel); border: 1px solid var(--border); border-radius: 10px; margin-bottom: 20px; overflow: hidden; scroll-margin-top: 24px; }
    .scenario-header, .step-header { display: flex; justify-content: space-between; gap: 16px; align-items: flex-start; padding: 16px 18px; border-bottom: 1px solid var(--border); }
    .qualities { display: flex; flex-wrap: wrap; gap: 6px; }
    .qualities span { border: 1px solid var(--border); color: var(--muted); border-radius: 999px; padding: 2px 8px; font-size: 12px; }
    .badge { border-radius: 999px; padding: 3px 10px; text-transform: uppercase; font-size: 12px; font-weight: 800; background: var(--soft); color: var(--muted); }
    .badge.ok, .flow-node.ok em { color: var(--ok); }
    .badge.changed, .flow-node.changed em { color: var(--changed); }
    .badge.failed, .badge.error, .flow-node.failed em, .flow-node.error em { color: var(--failed); }
    .flowchart { display: flex; gap: 8px; align-items: stretch; overflow-x: auto; padding: 16px 18px; border-bottom: 1px solid var(--border); }
    .flow-node { min-width: 160px; background: #0f1318; border: 1px solid var(--border); border-radius: 8px; color: var(--text); text-decoration: none; padding: 10px; }
    .flow-node.failed, .flow-node.error { border-color: rgba(255, 107, 95, 0.8); box-shadow: 0 0 0 1px rgba(255, 107, 95, 0.2) inset; }
    .flow-node span, .flow-node em { display: block; color: var(--muted); font-size: 11px; font-style: normal; text-transform: uppercase; }
    .connector { color: var(--muted); align-self: center; }
    .step { padding: 0 18px 18px; border-top: 1px solid var(--border); scroll-margin-top: 24px; }
    .step-header { margin: 0 -18px 14px; }
    .detail, .assertion pre, .artifact pre { background: #080a0d; border: 1px solid var(--border); border-radius: 8px; padding: 12px; overflow: auto; }
    .assertions { display: grid; gap: 10px; }
    .assertion { border: 1px solid var(--border); border-radius: 8px; padding: 12px; background: #10141a; }
    .assertion.failed, .assertion.error { border-color: rgba(255, 107, 95, 0.75); }
    .assertion-title { display: flex; justify-content: space-between; gap: 12px; }
    .assertion-title span { color: var(--muted); text-transform: uppercase; font-size: 12px; font-weight: 800; }
    .diff-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 12px; }
    .copy-block-header { display: flex; justify-content: space-between; gap: 8px; align-items: center; }
    .copy-block-header h4 { margin-bottom: 6px; }
    .artifact { border-top: 1px solid var(--border); margin: 12px -18px 0; padding: 0 18px; }
    .artifact summary { cursor: pointer; padding: 12px 0; font-weight: 700; display: flex; justify-content: space-between; gap: 12px; align-items: center; }
    @media (max-width: 900px) { .layout { grid-template-columns: 1fr; } .rail { position: static; border-right: none; border-bottom: 1px solid var(--border); padding: 0 0 16px; } .diff-grid { grid-template-columns: 1fr; } }
    """
}
