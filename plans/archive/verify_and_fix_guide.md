# QEMU Adapter Test Guide Verification and Fix

## Objective
Review and improve the QEMU_ADAPTER_TEST_GUIDE.md to ensure it is clear, accurate, and easy to follow for both humans and AI agents.

## Steps

1. Read the current guide at `/home/luandro/Dev/coolab/mesha/QEMU_ADAPTER_TEST_GUIDE.md`.
2. Check for the following:
   - Accuracy: Ensure all commands, paths, and descriptions match the actual project structure and scripts.
   - Completeness: Verify that all necessary steps, prerequisites, and notes are included.
   - Clarity: Make sure the language is direct and unambiguous, suitable for AI agents to follow.
   - Structure: Ensure the guide is well-organized with clear separation between quick test (prebuilt) and full test (source) paths.
   - Correctness of examples: Verify that command examples are correct and use proper paths.
   - Markdown formatting: Ensure the guide uses proper markdown for readability.

3. Make necessary improvements:
   - Correct any inaccuracies (e.g., wrong script paths, missing sudo notes).
   - Add missing steps or notes (e.g., waiting times, troubleshooting tips).
   - Improve readability: use consistent formatting, bullet points, and code fences for commands.
   - Ensure the guide is suitable for AI agents to follow (i.e., explicit, step-by-step, no ambiguous language).

4. Write the updated guide back to `/home/luandro/Dev/coolab/mesha/QEMU_ADAPTER_TEST_GUIDE.md`.

## Notes
- Do not modify other files unless they are clearly incorrect and related to the guide (e.g., if a script path mentioned in the guide is wrong, we note it in the guide as a troubleshooting point, but we do not change the script itself unless it is a simple typo that is obviously a mistake and we are sure it is safe to fix).
- Keep the guide concise but complete.
- Use the existing style: code fences for commands, bold for file names, etc.
- After making changes, we can optionally do a quick sanity check by reading the updated guide to ensure it makes sense.

## Expected Outcome
An updated QEMU_ADAPTER_TEST_GUIDE.md that is clear, accurate, and easy to follow for both humans and AI agents to perform the QEMU adapter tests.