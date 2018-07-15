VERSION := $(shell node -e "x=$$(cat dist/manifest.json); console.log(x.version)")
SRCPKG_DIR = tab-stash-src-$(VERSION)
SRC_PKG = $(SRCPKG_DIR).tar.gz
DIST_PKG = tab-stash-$(VERSION).zip

# Primary (user-facing) targets
debug: build-dbg
.PHONY: debug

release: pkg-webext pkg-source
	make -C $(SRCPKG_DIR) release-preflight build-rel
	[ -z "$$(diff -Nru dist $(SRCPKG_DIR)/dist)" ]
	@echo ""
	@echo "Ready for release $(VERSION)!"
	@echo ""
.PHONY: release



# Intermediate targets.
#
# Rather than calling webpack directly, we invoke npm here so that Windows users
# still have a way to build.
pkg-webext: release-preflight build-rel
	cd dist && zip -9rvo ../$(DIST_PKG) .
.PHONY: pkg-webext

pkg-source: release-preflight
	rm -rf $(SRCPKG_DIR) $(SRC_PKG)
	git clone . $(SRCPKG_DIR)
	git -C $(SRCPKG_DIR) remote set-url origin "$$(git remote get-url origin)"
	git fetch -f origin
	tar -czf $(SRC_PKG) $(SRCPKG_DIR)
.PHONY: pkg-source

build-dbg: node_modules
	npm run build
.PHONY: build-dbg

build-rel: node_modules clean
	npm run build-rel
	./node_modules/.bin/web-ext lint -s dist
.PHONY: build-rel

release-preflight:
	[ -z "$$(git status --porcelain)" ] # Working tree must be clean.
	[ "$$(git name-rev --tags --name-only HEAD)" == "v$(VERSION)" ] # HEAD must be pointing at the release tag which matches manifest.json.
.PHONY: release-preflight

node_modules: package.json package-lock.json
	npm install
	touch node_modules

# Cleanup targets
distclean: clean
	rm -rf node_modules $(SRCPKG_DIR) $(SRC_PKG) $(DIST_PKG)
.PHONY: distclean

clean:
	rm -f dist/*.js
.PHONY: clean
