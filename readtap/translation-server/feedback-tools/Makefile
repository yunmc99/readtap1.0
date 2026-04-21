.PHONY: help aggregate cross-ref review weekly clean

# ── Phase 2 feedback automation — operator cadence ───────────────────
#
# Weekly cadence (typically Monday morning):
#   make weekly    → runs aggregate + cross-ref, no human interaction
#   make review    → opens the interactive approval CLI on the latest
#                    tier-3 report. Process as many as you have time for;
#                    resume anytime with the same command.
#
# See feedback-tools/README.md for the full operator runbook.

help:
	@echo "Phase 2 feedback automation helpers."
	@echo ""
	@echo "Weekly operator workflow:"
	@echo "  make weekly     Run aggregate + cross-ref (no prompting)"
	@echo "  make review     Review the latest tier3 report interactively"
	@echo ""
	@echo "Individual steps (if needed):"
	@echo "  make aggregate  Tier 2 batch — group+classify new feedback"
	@echo "  make cross-ref  Tier 3 — score promoted candidates"
	@echo "  make clean      Remove .cache/ and old reports"

aggregate:
	python3 aggregate.py --days 7

cross-ref:
	@latest=$$(ls -t reports/*-aggregate.json 2>/dev/null | head -1); \
	if [ -z "$$latest" ]; then \
	  echo "[error] no aggregate report found — run 'make aggregate' first"; \
	  exit 1; \
	fi; \
	python3 cross_ref.py --input "$$latest"

review:
	@latest=$$(ls -t reports/*-tier3.json 2>/dev/null | head -1); \
	if [ -z "$$latest" ]; then \
	  echo "[error] no tier3 report found — run 'make cross-ref' first"; \
	  exit 1; \
	fi; \
	python3 review.py --input "$$latest"

weekly: aggregate cross-ref
	@echo ""
	@echo "[weekly] aggregate + cross-ref complete."
	@echo "[weekly] → run 'make review' to approve/reject candidates."

clean:
	rm -rf .cache reports/*.json
