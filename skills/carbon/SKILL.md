---
name: carbon
description: Report the energy, water, and CO2e footprint of Claude Code usage, with offset balance and cost-to-clear
---

Run this command and present its output to the user verbatim. Do not paraphrase,
reformat, or omit the caveat line.

```bash
bash "${CARBON_LEDGER_DIR:-$HOME/Documents/Research/carbon-tracker/carbon-ledger}/scripts/carbon-report.sh"
```

Notes for the agent:

- The headline UNOFFSET BALANCE counts verified removal only. Prevention and
  unverified rows are separate lines by design — never add them together.
- If the user asks to purchase offsets, show the links the report prints and let
  the user click them; never fetch them yourself and never automate a payment.
- If the user wants to record a purchase they made, use the /carbon-offset skill.
