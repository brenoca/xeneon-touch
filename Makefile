APP   := $(HOME)/Applications/XeneonTouch.app
AGENT := $(HOME)/Library/LaunchAgents/local.xeneon-touch.plist

build:
	swiftc -O -o xeneon-touch main.swift

install: build
	mkdir -p $(APP)/Contents/MacOS
	cp Info.plist $(APP)/Contents/
	cp xeneon-touch $(APP)/Contents/MacOS/
	codesign --force -s - --identifier local.xeneon-touch $(APP)
	sed 's|__APP__|$(APP)|' local.xeneon-touch.plist > $(AGENT)
	launchctl bootout gui/$$(id -u)/local.xeneon-touch 2>/dev/null || true
	launchctl bootstrap gui/$$(id -u) $(AGENT)

uninstall:
	launchctl bootout gui/$$(id -u)/local.xeneon-touch 2>/dev/null || true
	rm -rf $(APP) $(AGENT)

restart:
	launchctl kickstart -k gui/$$(id -u)/local.xeneon-touch

log:
	tail -f /tmp/xeneon-touch.log
