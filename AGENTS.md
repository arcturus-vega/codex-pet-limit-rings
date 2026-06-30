# Codex Pet Limit Rings Agent Notes

## Goal

This repository packages `codex-pet-limit-rings`: a native macOS companion app that draws usage-limit rings around the current Codex pet without patching Codex.

## Primary Contract

- Keep the Codex app bundle unmodified.
- Treat `tools/codex-pet-limit-rings.swift` as the app source.
- Treat `tools/install-limit-rings.sh` and `tools/uninstall-limit-rings.sh` as the public install/uninstall path.
- Treat `skills/codex-pet-limit-rings/SKILL.md` as the reusable Codex-agent workflow.
- Keep weather-pet code under `experiments/weather-pets/`; it is not the main package.

## Done When

For app changes, verify:

```bash
tools/validate-limit-rings.sh
```

That script checks shell syntax, compiles the app source, renders previews for every ring style, builds the app bundle, and runs `git diff --check` when the checkout is a Git repository.

For packaged installs, also run `tools/install-limit-rings.sh` and verify:

```bash
pgrep -fl CodexPetLimitRings
launchctl print "gui/$(id -u)/com.codex-pet.limit-rings" >/dev/null
```

Do not commit `tmp/`, local logs, screenshots, user Codex state, or generated private pet assets.
