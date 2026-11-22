# Thin wrapper over the scripts in app/scripts, which build with app/Ceviche.xcodeproj and test with SwiftPM. Variables can be given on the command line
# (make build CONFIGURATION=debug) or exported in the environment. Team ID, bundle ID, iCloud container,
# signing certificate and Ceviche Pro product ID come from build.config (git-ignored; copy build.config.example), not from here.

CONFIGURATION ?= release
export CEVICHE_TEAM_ID CEVICHE_BUNDLE_ID CEVICHE_ICLOUD CEVICHE_ICLOUD_CONTAINER CEVICHE_SIGN_IDENTITY CEVICHE_PROVISIONING_PROFILE CEVICHE_LOCAL_STORAGE CEVICHE_DISTRIBUTION CEVICHE_SANDBOX CEVICHE_STORE_PRODUCTS CEVICHE_NOTARY_PROFILE

.PHONY: all build debug dev run xcode vendor snapshot snapshot-local presets test test-slow models models-prebuilt models-install models-uninstall models-package models-pin clean help
.DEFAULT_GOAL := build

build:                       ## Release build and signed bundle at app/dist/Ceviche.app
	app/scripts/build.sh $(CONFIGURATION)

debug:                       ## Same, unstripped, for lldb
	$(MAKE) build CONFIGURATION=debug

dev:                         ## Debug build (fast incremental), then quit and relaunch the app
	$(MAKE) build CONFIGURATION=debug
	@pkill -x Ceviche && while pgrep -x Ceviche >/dev/null; do sleep 0.1; done; true
	@# Launch Services can refuse the open (-600) while the old instance is still deregistering.
	open app/dist/Ceviche.app || (sleep 1 && open app/dist/Ceviche.app)

run: build                   ## Build, then open the app
	open app/dist/Ceviche.app

vendor:                      ## Build the codec frameworks the package links; once, before opening the project in Xcode
	app/scripts/vendor.sh

xcode: vendor                ## Write Platforms/macOS/Config/Local.xcconfig from build.config, then open app/Ceviche.xcodeproj
	app/scripts/build.sh --configure
	open app/Ceviche.xcodeproj

snapshot:                    ## Test build for internal testers: the app in app/dist/snapshots/*.zip, notarized; MODELS=1 adds the model set zip
	app/scripts/snapshot.sh $(if $(MODELS),--models)

snapshot-local:              ## The same zip without notarization, to try on this Mac; nothing is sent to Apple
	app/scripts/snapshot.sh --local $(if $(MODELS),--models)

presets:                     ## Download the open-source preset packs into presets/ (pinned; git-ignored; the build runs it)
	presets/fetch-presets.sh

test:                        ## Test suite, without the slow tier or the review tools (pass FILTER=Suite/testName to narrow)
	app/scripts/test.sh --skip ReviewTools $(if $(FILTER),--filter "$(FILTER)")

test-slow:                   ## Also GPU-vs-CPU comparisons, Core ML models and full-size RAW exports
	CEVICHE_SLOW_TESTS=1 app/scripts/test.sh --skip ReviewTools $(if $(FILTER),--filter "$(FILTER)")

models:                      ## Convert the Core ML models into models/build for debug builds (never committed or bundled)
	models/fetch-models.sh

models-prebuilt:             ## Download the pinned model set into models/build instead (no Python needed)
	models/fetch-models.sh --prebuilt

models-install:              ## Install the models in models/build into this user's model library, as the Models window would, to test a release build
	models/install-models.sh

models-uninstall:            ## Remove them from the model library again
	models/install-models.sh --uninstall

models-package:              ## Zip models/build into models/dist as model set TAG=models-vN (the Models workflow runs this)
	models/package-models.sh $(TAG)

models-pin:                  ## Pin the published model set TAG=models-vN in the app (CevicheCore/Resources/ModelSet.json)
	@test -n "$(TAG)" || { echo "usage: make models-pin TAG=models-vN"; exit 2; }
	curl -fsSL --retry 3 -o app/Sources/CevicheCore/Resources/ModelSet.json "https://github.com/ChiChou/Ceviche/releases/download/$(TAG)/ModelSet.json"
	@python3 -I -c 'import json; m = json.load(open("app/Sources/CevicheCore/Resources/ModelSet.json")); print("Pinned", m["tag"], "with", len(m["models"]), "models; commit the manifest.")'

clean:                       ## Remove build products and caches
	rm -rf app/.build app/dist app/Vendor/Frameworks

help:                        ## This list
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | sed -E 's/:[^#]*##/\t/' | column -t -s "$$(printf '\t')"
	@printf '\nVariables: CONFIGURATION=%s  TAG=models-vN  CEVICHE_SIGN_IDENTITY  CEVICHE_PROVISIONING_PROFILE  CEVICHE_LOCAL_STORAGE=folders|database  CEVICHE_ICLOUD=1|0  CEVICHE_DISTRIBUTION=community|appstore  CEVICHE_SANDBOX=1|0  CEVICHE_STORE_PRODUCTS  MODELS=1  FILTER. Signing: build.config\n' "$(CONFIGURATION)"
