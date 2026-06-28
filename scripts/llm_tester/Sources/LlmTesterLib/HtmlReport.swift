import Foundation

public enum HtmlReport {
    public static func write(summary: LlmTesterRunSummary, to outputPath: String) throws {
        let html = render(summary: summary)
        try html.write(toFile: outputPath, atomically: true, encoding: .utf8)
    }

    public static func render(summary: LlmTesterRunSummary) -> String {
        let sortedResults = sortedResults(summary.results)
        let hoistedPrompts = buildHoistedSystemPrompts(from: sortedResults)
        let counts = statusCounts(from: sortedResults)
        let subsystems = Array(Set(sortedResults.map(\.scenario.subsystem))).sorted()
        let statuses = ["error", "invalid_json", "ok"]

        var html: [String] = []
        html.append("<!DOCTYPE html>")
        html.append("<html lang=\"en\">")
        html.append("<head>")
        html.append("<meta charset=\"utf-8\">")
        html.append("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">")
        html.append("<title>LLM Tester Report</title>")
        html.append("<link rel=\"stylesheet\" href=\"https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11.9.0/build/styles/github-dark.min.css\">")
        html.append("<script src=\"https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11.9.0/build/highlight.min.js\"></script>")
        html.append("<script src=\"https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11.9.0/build/languages/json.min.js\"></script>")
        html.append("<style>")
        html.append(
            """
            :root { color-scheme: dark; --bg: #0d1117; --panel: #161b22; --border: #30363d; --text: #e6edf3; --muted: #8b949e; --ok: #3fb950; --bad: #f85149; --warn: #d29922; }
            body { margin: 0; font-family: ui-sans-serif, system-ui, -apple-system, sans-serif; background: var(--bg); color: var(--text); line-height: 1.5; }
            main { max-width: 1400px; margin: 0 auto; padding: 24px; }
            .layout { display: flex; gap: 0; align-items: flex-start; }
            .toc { flex: 0 0 260px; position: sticky; top: 24px; max-height: calc(100vh - 48px); overflow-y: auto; border-right: 1px solid var(--border); padding: 0 16px 24px 0; margin-right: 24px; }
            .toc-heading { font-size: 14px; text-transform: uppercase; letter-spacing: 0.04em; color: var(--muted); margin: 0 0 12px; }
            .toc-list { list-style: none; margin: 0; padding: 0; }
            .toc-item { margin-bottom: 4px; }
            .toc-item.hidden { display: none; }
            .toc-link { display: flex; align-items: center; justify-content: space-between; gap: 8px; padding: 6px 10px; border-radius: 8px; text-decoration: none; color: var(--text); font-size: 13px; border: 1px solid transparent; }
            .toc-link:hover { background: rgba(88, 166, 255, 0.08); border-color: var(--border); }
            .toc-label { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
            .toc-link .badge { flex-shrink: 0; font-size: 10px; padding: 1px 6px; }
            .content { flex: 1; min-width: 0; }
            @media (max-width: 860px) {
              .layout { flex-direction: column; }
              .toc { flex: none; position: static; max-height: none; width: 100%; border-right: none; border-bottom: 1px solid var(--border); padding: 0 0 16px; margin: 0 0 16px; overflow-x: auto; overflow-y: hidden; }
              .toc-list { display: flex; flex-wrap: nowrap; gap: 8px; }
              .toc-item { margin-bottom: 0; flex-shrink: 0; }
              .toc-link { white-space: nowrap; }
            }
            h1, h2, h3 { line-height: 1.2; }
            .report-header { display: flex; flex-wrap: wrap; gap: 12px 16px; align-items: center; justify-content: space-between; margin-bottom: 4px; }
            .report-header h1 { margin: 0; }
            .report-actions { display: flex; flex-wrap: wrap; gap: 8px; }
            .summary { display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: 12px; margin: 20px 0 28px; }
            .metric { background: var(--panel); border: 1px solid var(--border); border-radius: 10px; padding: 14px 16px; }
            .metric .label { color: var(--muted); font-size: 12px; text-transform: uppercase; letter-spacing: 0.04em; }
            .metric .value { font-size: 24px; font-weight: 600; margin-top: 4px; }
            .metric.ok .value { color: var(--ok); }
            .metric.invalid_json .value { color: var(--warn); }
            .metric.error .value { color: var(--bad); }
            .card { background: var(--panel); border: 1px solid var(--border); border-radius: 12px; margin-bottom: 16px; overflow: hidden; scroll-margin-top: 24px; }
            .card-header { display: flex; flex-wrap: wrap; gap: 10px 16px; align-items: center; justify-content: space-between; padding: 16px 18px; border-bottom: 1px solid var(--border); }
            .card-header h2 { margin: 0; font-size: 18px; }
            .card-subtitle { margin: 6px 0 0; font-size: 14px; color: var(--text); font-weight: 500; }
            .card-description { margin: 6px 0 0; font-size: 14px; color: var(--muted); line-height: 1.45; }
            .meta { color: var(--muted); font-size: 13px; }
            .badge { display: inline-block; border-radius: 999px; padding: 2px 10px; font-size: 12px; font-weight: 600; text-transform: uppercase; }
            .badge.ok { background: rgba(63, 185, 80, 0.15); color: var(--ok); }
            .badge.invalid_json { background: rgba(210, 153, 34, 0.15); color: var(--warn); }
            .badge.error { background: rgba(248, 81, 73, 0.15); color: var(--bad); }
            .filters { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; margin: 0 0 20px; }
            .filters .group { display: flex; flex-wrap: wrap; gap: 6px; align-items: center; }
            .filters .group-label { color: var(--muted); font-size: 12px; text-transform: uppercase; letter-spacing: 0.04em; margin-right: 4px; }
            .filter-chip { border: 1px solid var(--border); background: var(--panel); color: var(--text); border-radius: 999px; padding: 4px 12px; font-size: 12px; font-weight: 600; cursor: pointer; }
            .filter-chip.active { border-color: #58a6ff; background: rgba(88, 166, 255, 0.15); color: #79c0ff; }
            .filter-chip.status-ok.active { border-color: var(--ok); background: rgba(63, 185, 80, 0.15); color: var(--ok); }
            .filter-chip.status-invalid_json.active { border-color: var(--warn); background: rgba(210, 153, 34, 0.15); color: var(--warn); }
            .filter-chip.status-error.active { border-color: var(--bad); background: rgba(248, 81, 73, 0.15); color: var(--bad); }
            .shared-prompts { margin-bottom: 24px; }
            .shared-prompts h2 { font-size: 20px; margin: 0 0 12px; }
            .shared-prompt-block { background: var(--panel); border: 1px solid var(--border); border-radius: 12px; margin-bottom: 12px; overflow: hidden; scroll-margin-top: 24px; }
            .shared-prompt-block .block-header { padding: 14px 18px; border-bottom: 1px solid var(--border); font-weight: 600; }
            .shared-prompt-block .block-meta { color: var(--muted); font-size: 12px; font-weight: 400; margin-top: 4px; }
            .prompt-ref summary { color: var(--muted); }
            .prompt-ref summary a { color: #79c0ff; text-decoration: none; }
            .prompt-ref summary a:hover { text-decoration: underline; }
            details { border-top: 1px solid var(--border); }
            details summary { cursor: pointer; padding: 12px 18px; font-weight: 600; }
            pre { margin: 0; padding: 0 18px 18px; overflow: auto; }
            code.hljs { background: #010409; border-radius: 8px; display: block; padding: 14px; font-size: 13px; }
            .error-box { margin: 0 18px 18px; padding: 12px 14px; border-radius: 8px; background: rgba(248, 81, 73, 0.12); color: #ffb1af; }
            .card.hidden { display: none; }
            .card-header-right { display: flex; flex-direction: column; align-items: flex-end; gap: 8px; }
            .card-actions { display: flex; flex-wrap: wrap; gap: 6px; justify-content: flex-end; }
            .copy-btn { border: 1px solid var(--border); background: #010409; color: var(--muted); border-radius: 6px; padding: 4px 10px; font-size: 12px; font-weight: 600; cursor: pointer; }
            .copy-btn:hover { color: var(--text); border-color: #484f58; }
            .copy-btn.copied { color: var(--ok); border-color: rgba(63, 185, 80, 0.4); }
            .copy-source { display: none; }
            """
        )
        html.append("</style>")
        html.append("</head>")
        html.append("<body>")
        html.append("<main>")
        html.append("<div class=\"report-header\">")
        html.append("<h1>LLM Tester Report</h1>")
        html.append("<div class=\"report-actions\">")
        html.append("<button type=\"button\" class=\"copy-btn copy-all-btn\" data-default-label=\"Copy All\">Copy All</button>")
        html.append("</div>")
        html.append("</div>")
        html.append(renderCopySource(text: allCopyText(for: sortedResults), cssClass: "copy-all-source"))
        html.append("<p class=\"meta\">Run \(escapeHTML(summary.generatedAt)) · Manifest \(escapeHTML(summary.manifestGeneratedAt)) · Provider preference \(escapeHTML(summary.providerPreference))</p>")
        html.append("<section class=\"summary\">")
        html.append(metric(label: "Scenarios", value: "\(summary.total)"))
        html.append(metric(label: "Succeeded", value: "\(summary.succeeded)"))
        html.append(metric(label: "Failed", value: "\(summary.failed)"))
        html.append(metric(label: "OK", value: "\(counts.ok)", cssClass: "ok"))
        html.append(metric(label: "Invalid JSON", value: "\(counts.invalidJSON)", cssClass: "invalid_json"))
        html.append(metric(label: "Error", value: "\(counts.error)", cssClass: "error"))
        html.append("</section>")

        if !hoistedPrompts.isEmpty {
            html.append(renderSharedSystemPrompts(hoistedPrompts))
        }

        html.append(renderFilters(subsystems: subsystems, statuses: statuses))
        html.append("<div class=\"layout\">")
        html.append(renderTableOfContents(results: sortedResults))
        html.append("<div class=\"content\">")
        html.append("<section id=\"scenario-cards\">")

        for result in sortedResults {
            html.append(renderCard(result: result, hoistedPrompts: hoistedPrompts))
        }

        html.append("</section>")
        html.append("</div>")
        html.append("</div>")
        html.append("</main>")
        html.append("<script>hljs.highlightAll();</script>")
        html.append(renderFilterScript())
        html.append(renderCopyScript())
        html.append("</body>")
        html.append("</html>")
        return html.joined(separator: "\n")
    }

    // MARK: - Sorting & counts

    public static func statusSortOrder(_ status: String) -> Int {
        switch status {
        case "error": return 0
        case "invalid_json": return 1
        case "ok": return 2
        default: return 3
        }
    }

    public static func sortedResults(_ results: [LlmTesterScenarioResult]) -> [LlmTesterScenarioResult] {
        results.sorted { statusSortOrder($0.status) < statusSortOrder($1.status) }
    }

    public static func statusCounts(from results: [LlmTesterScenarioResult]) -> (ok: Int, invalidJSON: Int, error: Int) {
        var ok = 0
        var invalidJSON = 0
        var error = 0
        for result in results {
            switch result.status {
            case "ok": ok += 1
            case "invalid_json": invalidJSON += 1
            case "error": error += 1
            default: break
            }
        }
        return (ok, invalidJSON, error)
    }

    // MARK: - Stimulus extraction

    public static func extractStimulusHeadline(from userPrompt: String) -> String? {
        if let stimulus = extractQuotedStimulus(from: userPrompt, prefix: "Stimulus: ") {
            return stimulus
        }
        for line in userPrompt.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("What reached you:") {
                return trimmed.dropFirst("What reached you:".count).trimmingCharacters(in: .whitespaces)
            }
        }
        guard let firstLine = userPrompt
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !firstLine.isEmpty
        else {
            return nil
        }
        return firstLine
    }

    private static func extractQuotedStimulus(from text: String, prefix: String) -> String? {
        guard let range = text.range(of: prefix) else { return nil }
        var remainder = text[range.upperBound...]
        guard remainder.first == "\"" else { return nil }
        remainder = remainder.dropFirst()
        var result = ""
        var escaped = false
        for char in remainder {
            if escaped {
                result.append(char)
                escaped = false
            } else if char == "\\" {
                escaped = true
            } else if char == "\"" {
                return result.isEmpty ? nil : result
            } else {
                result.append(char)
            }
        }
        return nil
    }

    // MARK: - Hoisted system prompts

    public struct HoistedSystemPrompt {
        let id: String
        let label: String
        let systemPrompt: String
        let scenarioIds: [String]
    }

    public static func buildHoistedSystemPrompts(from results: [LlmTesterScenarioResult]) -> [HoistedSystemPrompt] {
        var groups: [String: [LlmTesterScenarioResult]] = [:]
        var order: [String] = []
        for result in results {
            let key = result.scenario.systemPrompt
            if groups[key] == nil {
                order.append(key)
                groups[key] = []
            }
            groups[key]?.append(result)
        }

        var hoisted: [HoistedSystemPrompt] = []
        var index = 0
        for key in order {
            guard let group = groups[key], group.count >= 2 else { continue }
            let subsystems = Set(group.map(\.scenario.subsystem))
            let label: String
            if subsystems.count == 1, let subsystem = subsystems.first {
                label = "\(subsystem) (\(group.count) scenarios)"
            } else {
                label = "\(group.count) scenarios across \(subsystems.count) subsystems"
            }
            hoisted.append(
                HoistedSystemPrompt(
                    id: "system-prompt-\(index)",
                    label: label,
                    systemPrompt: key,
                    scenarioIds: group.map(\.scenario.id)
                )
            )
            index += 1
        }
        return hoisted
    }

    private static func hoistedPromptId(for systemPrompt: String, hoistedPrompts: [HoistedSystemPrompt]) -> String? {
        hoistedPrompts.first { $0.systemPrompt == systemPrompt }?.id
    }

    private static func renderSharedSystemPrompts(_ prompts: [HoistedSystemPrompt]) -> String {
        var parts: [String] = []
        parts.append("<section class=\"shared-prompts\">")
        parts.append("<h2>Shared System Prompts</h2>")
        for prompt in prompts {
            parts.append("<div class=\"shared-prompt-block\" id=\"\(escapeHTML(prompt.id))\">")
            parts.append("<div class=\"block-header\">")
            parts.append("\(escapeHTML(prompt.label))")
            parts.append("<div class=\"block-meta\">Used by: \(escapeHTML(prompt.scenarioIds.joined(separator: ", ")))</div>")
            parts.append("</div>")
            parts.append(section(title: "System Prompt", language: "plaintext", text: prompt.systemPrompt, open: false))
            parts.append("</div>")
        }
        parts.append("</section>")
        return parts.joined(separator: "\n")
    }

    // MARK: - Table of contents

    public static func scenarioAnchorId(for scenarioId: String) -> String {
        let sanitized = scenarioId.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" {
                return Character(scalar)
            }
            return "-"
        }
        return "scenario-\(String(sanitized))"
    }

    private static func renderTableOfContents(results: [LlmTesterScenarioResult]) -> String {
        var parts: [String] = []
        parts.append("<nav class=\"toc\" aria-label=\"Scenario table of contents\">")
        parts.append("<h2 class=\"toc-heading\">Scenarios</h2>")
        parts.append("<ul class=\"toc-list\">")
        for result in results {
            let anchorId = scenarioAnchorId(for: result.scenario.id)
            let label = result.scenario.id
            parts.append(
                "<li class=\"toc-item\" data-subsystem=\"\(escapeHTML(result.scenario.subsystem))\" data-status=\"\(escapeHTML(result.status))\">"
            )
            parts.append("<a class=\"toc-link\" href=\"#\(escapeHTML(anchorId))\">")
            parts.append("<span class=\"toc-label\">\(escapeHTML(label))</span>")
            parts.append("<span class=\"badge \(escapeHTML(result.status))\">\(escapeHTML(result.status))</span>")
            parts.append("</a></li>")
        }
        parts.append("</ul>")
        parts.append("</nav>")
        return parts.joined(separator: "\n")
    }

    // MARK: - Filters

    private static func renderFilters(subsystems: [String], statuses: [String]) -> String {
        var parts: [String] = []
        parts.append("<div class=\"filters\" id=\"scenario-filters\">")
        parts.append("<div class=\"group\">")
        parts.append("<span class=\"group-label\">Subsystem</span>")
        parts.append("<button type=\"button\" class=\"filter-chip active\" data-filter-type=\"subsystem\" data-filter-value=\"all\">All</button>")
        for subsystem in subsystems {
            parts.append(
                "<button type=\"button\" class=\"filter-chip active\" data-filter-type=\"subsystem\" data-filter-value=\"\(escapeHTML(subsystem))\">\(escapeHTML(subsystem))</button>"
            )
        }
        parts.append("</div>")
        parts.append("<div class=\"group\">")
        parts.append("<span class=\"group-label\">Status</span>")
        parts.append("<button type=\"button\" class=\"filter-chip active status-all\" data-filter-type=\"status\" data-filter-value=\"all\">All</button>")
        for status in statuses {
            parts.append(
                "<button type=\"button\" class=\"filter-chip active status-\(escapeHTML(status))\" data-filter-type=\"status\" data-filter-value=\"\(escapeHTML(status))\">\(escapeHTML(status))</button>"
            )
        }
        parts.append("</div>")
        parts.append("</div>")
        return parts.joined(separator: "\n")
    }

    private static func renderFilterScript() -> String {
        """
        <script>
        (function () {
          const cards = Array.from(document.querySelectorAll('#scenario-cards .card'));
          const tocItems = Array.from(document.querySelectorAll('.toc-item'));
          const chips = Array.from(document.querySelectorAll('#scenario-filters .filter-chip'));
          const activeSubsystems = new Set();
          const activeStatuses = new Set();

          function initGroup(type) {
            chips.filter(function (chip) { return chip.dataset.filterType === type; }).forEach(function (chip) {
              if (chip.dataset.filterValue === 'all') return;
              if (type === 'subsystem') activeSubsystems.add(chip.dataset.filterValue);
              if (type === 'status') activeStatuses.add(chip.dataset.filterValue);
            });
          }

          function syncChip(chip, activeSet) {
            const value = chip.dataset.filterValue;
            if (value === 'all') {
              chip.classList.toggle('active', activeSet.size === chips.filter(function (c) {
                return c.dataset.filterType === chip.dataset.filterType && c.dataset.filterValue !== 'all';
              }).length);
              return;
            }
            chip.classList.toggle('active', activeSet.has(value));
          }

          function applyFilters() {
            function matchesFilters(element) {
              const subsystem = element.dataset.subsystem;
              const status = element.dataset.status;
              const subsystemMatch = activeSubsystems.size === 0 || activeSubsystems.has(subsystem);
              const statusMatch = activeStatuses.size === 0 || activeStatuses.has(status);
              return subsystemMatch && statusMatch;
            }

            cards.forEach(function (card) {
              card.classList.toggle('hidden', !matchesFilters(card));
            });
            tocItems.forEach(function (item) {
              item.classList.toggle('hidden', !matchesFilters(item));
            });
          }

          initGroup('subsystem');
          initGroup('status');

          chips.forEach(function (chip) {
            chip.addEventListener('click', function () {
              const type = chip.dataset.filterType;
              const value = chip.dataset.filterValue;
              const activeSet = type === 'subsystem' ? activeSubsystems : activeStatuses;
              const groupChips = chips.filter(function (c) { return c.dataset.filterType === type; });

              if (value === 'all') {
                activeSet.clear();
                groupChips.forEach(function (c) {
                  if (c.dataset.filterValue !== 'all') activeSet.add(c.dataset.filterValue);
                });
              } else if (activeSet.has(value)) {
                activeSet.delete(value);
              } else {
                activeSet.add(value);
              }

              groupChips.forEach(function (c) { syncChip(c, activeSet); });
              applyFilters();
            });
          });
        })();
        </script>
        """
    }

    // MARK: - Copy

    public static func responseCopyText(for result: LlmTesterScenarioResult) -> String? {
        if let prettyJSON = result.prettyJSON {
            return prettyJSON
        }
        return result.rawText
    }

    public static func fullCopyText(for result: LlmTesterScenarioResult) -> String {
        var parts = ["--- Scenario: \(result.scenario.id) ---\n\n", result.combinedPrompt]
        if let response = responseCopyText(for: result) {
            parts.append("\n\n--- Response ---\n\n")
            parts.append(response)
        }
        return parts.joined()
    }

    public static func allCopyText(for results: [LlmTesterScenarioResult]) -> String {
        sortedResults(results).map(fullCopyText(for:)).joined(separator: "\n\n")
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

          document.querySelectorAll('.copy-btn:not(.copy-all-btn)').forEach(function (button) {
            button.addEventListener('click', function () {
              const card = button.closest('.card');
              if (!card) return;
              copyFromSource(button, card.querySelector('.copy-source'));
            });
          });
        })();
        </script>
        """
    }

    // MARK: - Cards & sections

    private static func metric(label: String, value: String, cssClass: String? = nil) -> String {
        let classAttr = cssClass.map { " \($0)" } ?? ""
        return """
        <div class="metric\(classAttr)"><div class="label">\(escapeHTML(label))</div><div class="value">\(escapeHTML(value))</div></div>
        """
    }

    private static func renderCard(result: LlmTesterScenarioResult, hoistedPrompts: [HoistedSystemPrompt]) -> String {
        var parts: [String] = []
        let anchorId = scenarioAnchorId(for: result.scenario.id)
        parts.append(
            "<article class=\"card\" id=\"\(escapeHTML(anchorId))\" data-subsystem=\"\(escapeHTML(result.scenario.subsystem))\" data-status=\"\(escapeHTML(result.status))\">"
        )
        parts.append("<div class=\"card-header\">")
        parts.append("<div>")
        parts.append("<h2>\(escapeHTML(result.scenario.label))</h2>")
        if let headline = extractStimulusHeadline(from: result.scenario.userPrompt) {
            parts.append("<p class=\"card-subtitle\">\(escapeHTML(headline))</p>")
        }
        if !result.scenario.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("<p class=\"card-description\">\(escapeHTML(result.scenario.description))</p>")
        }
        parts.append("<div class=\"meta\">\(escapeHTML(result.scenario.id)) · \(escapeHTML(result.scenario.subsystem))</div>")
        parts.append("</div>")
        parts.append("<div class=\"card-header-right\">")
        parts.append("<div class=\"card-actions\">")
        parts.append(
            "<button type=\"button\" class=\"copy-btn\" data-default-label=\"Copy\">Copy</button>"
        )
        parts.append("</div>")
        parts.append("<div class=\"meta\">")
        if let provider = result.provider {
            parts.append("\(escapeHTML(provider)) · ")
        }
        parts.append("\(result.durationMs) ms · <span class=\"badge \(escapeHTML(result.status))\">\(escapeHTML(result.status))</span>")
        parts.append("</div>")
        parts.append("</div>")
        parts.append("</div>")

        parts.append(renderCopySource(text: fullCopyText(for: result)))

        if let errorMessage = result.errorMessage, result.status == "error" || result.status == "invalid_json" {
            parts.append("<div class=\"error-box\">\(escapeHTML(errorMessage))</div>")
        }

        if let hoistedId = hoistedPromptId(for: result.scenario.systemPrompt, hoistedPrompts: hoistedPrompts) {
            parts.append(hoistedSystemPromptReference(id: hoistedId))
        } else {
            parts.append(section(title: "System Prompt", language: "plaintext", text: result.scenario.systemPrompt, open: false))
        }

        parts.append(section(title: "User Prompt", language: "plaintext", text: result.scenario.userPrompt, open: false))

        if !result.scenario.jsonSchema.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(section(title: "JSON Schema", language: "json", text: result.scenario.jsonSchema, open: false))
        }

        parts.append(section(title: "Debug: combined prompt", language: "plaintext", text: result.combinedPrompt, open: false))

        if let prettyJSON = result.prettyJSON {
            parts.append(section(title: "Response JSON", language: "json", text: prettyJSON, open: true))
        } else if let rawText = result.rawText {
            let language = result.jsonValid ? "json" : "plaintext"
            parts.append(section(title: "Response", language: language, text: rawText, open: true))
        }

        parts.append("</article>")
        return parts.joined(separator: "\n")
    }

    private static func hoistedSystemPromptReference(id: String) -> String {
        """
        <details class="prompt-ref">
          <summary><a href="#\(escapeHTML(id))">▸ System prompt (shared)</a></summary>
        </details>
        """
    }

    private static func section(title: String, language: String, text: String, open: Bool) -> String {
        let openAttr = open ? " open" : ""
        return """
        <details\(openAttr)>
          <summary>\(escapeHTML(title))</summary>
          <pre><code class="language-\(escapeHTML(language))">\(escapeHTML(text))</code></pre>
        </details>
        """
    }

    public static func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
