// Phase 1 stub. Real integration (Pi via MCP) is deferred to a later phase.
//
// The stub returns immediately so the full mechanical flow can be verified:
// Ctrl+K opens popup → user types prompt → Enter submits →
// editor locked → result applied → editor unlocked.
class AiService {
  Future<String> getCompletion({
    required String documentText,
    required String editTarget,
    required String prompt,
  }) async {
    // Deterministic output makes the flow easy to test manually.
    return '[AI: $prompt]';
  }

  // No-op for now. Will close the HTTP client / cancel in-flight requests
  // when real AI integration lands.
  void dispose() {}
}
