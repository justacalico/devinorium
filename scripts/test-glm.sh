#!/usr/bin/env bash
# Run the glm-5-2 integration tests locally.
#
# Requires: devin CLI on PATH, authenticated (`devin login`).
# These tests use the free glm-5-2 model and exercise:
#   - model listing
#   - text + multi-turn conversation
#   - image attachments
#   - text attachments
#   - code generation
#   - file writing (accept-edits)
#   - all permission modes
set -euo pipefail
cd "$(dirname "$0")/.."

echo "Running glm-5-2 provider tests (requires devin CLI + auth)..."
cargo test --test provider -- --ignored --nocapture --test-threads=1
