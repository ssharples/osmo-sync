APP := build/dd/Build/Products/Release/OsmoSync.app
AGENT := com.ssharples.OsmoSync
AGENT_PLIST := $(HOME)/Library/LaunchAgents/$(AGENT).plist
# Sign with your Apple Development certificate when there is one. A steady signature means
# macOS treats each new build as the same app, so the keychain stops asking about the Wi-Fi
# password after every update. Falls back to ad-hoc signing.
SIGN_ID ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development/ {print $$2; exit}')

.PHONY: test app run install uninstall clean

test:
	cd Packages/OsmoSyncCore && swift test

app:
	xcodegen generate -q
	xcodebuild -project OsmoSync.xcodeproj -scheme OsmoSync -configuration Release -derivedDataPath build/dd build -quiet

run: app
	open "$(APP)"

# Puts the app in /Applications and a login agent in ~/Library/LaunchAgents that starts it
# at login and restarts it after a crash. Quitting from the menu keeps it quit.
install: app
	-launchctl bootout gui/$$(id -u)/$(AGENT) 2>/dev/null
	-pkill -x OsmoSync; sleep 1
	rm -rf /Applications/OsmoSync.app
	cp -R "$(APP)" /Applications/
	codesign --force --deep --sign "$(or $(SIGN_ID),-)" /Applications/OsmoSync.app
	mkdir -p "$(HOME)/Library/LaunchAgents"
	cp Support/$(AGENT).plist "$(AGENT_PLIST)"
	launchctl bootstrap gui/$$(id -u) "$(AGENT_PLIST)"

uninstall:
	-launchctl bootout gui/$$(id -u)/$(AGENT) 2>/dev/null
	rm -f "$(AGENT_PLIST)"
	rm -rf /Applications/OsmoSync.app

clean:
	rm -rf build OsmoSync.xcodeproj
