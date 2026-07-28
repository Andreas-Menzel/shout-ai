# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Andreas Menzel
.PHONY: help setup build test bundle run cli cert screenshots recordings reset-permissions clean

# Default to help, so a bare `make` never kicks off a 1.6 GB download.
.DEFAULT_GOAL := help

help:
	@echo "Shout — make targets"
	@echo ""
	@echo "  test               run the unit tests (works from a fresh clone)"
	@echo "  build              swift build -c release"
	@echo "  setup              one-time: download the 1.6 GB speech model"
	@echo "  cert               one-time: stable signing identity (asks for your password)"
	@echo "  bundle             assemble a signed build/Shout.app"
	@echo "  run                bundle + open the app"
	@echo "  cli                build just the shout-cli test harness"
	@echo "  screenshots        re-render docs/screenshots (off-screen, no display needed)"
	@echo "  recordings         re-render docs/recordings (needs ffmpeg)"
	@echo "  reset-permissions  clear stale TCC entries after a signature change"
	@echo "  clean              rm -rf .build build"
	@echo ""
	@echo "Building and testing need no setup step: SwiftPM fetches and verifies"
	@echo "the whisper.cpp framework itself. 'make setup' is only needed to dictate."

# One-time: fetch the ~1.6 GB speech model. The whisper.cpp framework is
# fetched by SwiftPM itself (see Package.swift), so `swift build` and
# `swift test` work straight from a fresh clone — this is only needed to
# actually dictate.
setup:
	scripts/fetch-model.sh

build:
	swift build -c release

test:
	swift test

# Assemble the signed Shout.app in build/
bundle:
	scripts/bundle.sh

run: bundle
	open build/Shout.app

cli:
	swift build -c release --product shout-cli

# Re-render the documentation media. Screenshots need no display (SwiftUI's
# ImageRenderer works off-screen); recordings additionally need ffmpeg.
screenshots:
	scripts/render-screenshots.sh

recordings:
	scripts/render-recording.sh

# One-time: create a stable self-signed signing identity so permissions
# survive rebuilds (asks for your login password — run it yourself).
cert:
	scripts/make-signing-cert.sh

# Clear Shout's stale privacy entries after a signature change, then
# re-grant them fresh in the app's Setup window.
reset-permissions:
	-tccutil reset Accessibility com.shoutai.Shout
	-tccutil reset ListenEvent com.shoutai.Shout
	-tccutil reset PostEvent com.shoutai.Shout
	-tccutil reset Microphone com.shoutai.Shout
	-tccutil reset AppleEvents com.shoutai.Shout

clean:
	rm -rf .build build
