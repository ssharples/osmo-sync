APP := build/dd/Build/Products/Release/OsmoSync.app

.PHONY: test app run install clean

test:
	cd Packages/OsmoSyncCore && swift test

app:
	xcodegen generate -q
	xcodebuild -project OsmoSync.xcodeproj -scheme OsmoSync -configuration Release -derivedDataPath build/dd build -quiet

run: app
	open "$(APP)"

# Copies the app into /Applications so it can start at login.
install: app
	rm -rf /Applications/OsmoSync.app
	cp -R "$(APP)" /Applications/
	open /Applications/OsmoSync.app

clean:
	rm -rf build OsmoSync.xcodeproj
