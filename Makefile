.PHONY: setup build bundle run cli cert reset-permissions clean

# One-time: fetch whisper.xcframework and the speech model.
setup:
	scripts/fetch-whisper.sh
	scripts/fetch-model.sh

build:
	swift build -c release

# Assemble the signed Shout.app in build/
bundle:
	scripts/bundle.sh

run: bundle
	open build/Shout.app

cli:
	swift build -c release --product shout-cli

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

clean:
	rm -rf .build build
