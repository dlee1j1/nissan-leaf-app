.PHONY: docker-build docker-shell docker-restart docker-stop docker-adb
CONTAINER_NAME=flutter_dev

# Most targets run inside the container so run docker-compose and exec to run make inside if not in the container
ifneq ($(shell [ -f /.dockerenv ] && echo 1),1)
# This is the host environment.
# FILE/NAME are forwarded so `make test-one FILE=... NAME=...` reaches the inner
# make (command-line vars are exported into the recipe environment by make, then
# `-e` hands them to the container).
%:
	@echo "Running '$@' inside container..."
	docker-compose up -d && docker-compose exec -T -e FILE -e NAME $(CONTAINER_NAME) make $@
else
# Flutter section - this stuff runs inside the container

.PHONY: setup run clean repomix android-engine-shim

# Pin the Flutter SDK to an exact release. Bump this on purpose; do NOT track a
# moving channel like "stable" -- that drift is what broke the Android release build.
FLUTTER_VERSION := 3.47.2

setup:
# install the flutter SDK if it's not there, then pin it to $(FLUTTER_VERSION)
	if [ ! -x "/opt/flutter/bin/flutter" ]; then \
	  echo "Flutter not found, cloning..."; \
	  git clone https://github.com/flutter/flutter.git /opt/flutter; \
	fi
	cd /opt/flutter && git fetch --tags --force
	cd /opt/flutter && [ "$$(git describe --tags --exact-match 2>/dev/null)" = "$(FLUTTER_VERSION)" ] \
	  || git -c advice.detachedHead=false checkout -f $(FLUTTER_VERSION)
	/opt/flutter/bin/flutter --version
	ln -sf /opt/android-tools /opt/flutter/bin/cache/artifacts/engine
	ln -sf nissan_leaf_app/.dart_tool .
	cd nissan_leaf_app && flutter config --enable-linux-desktop
	cd nissan_leaf_app && flutter pub get
	$(MAKE) android-engine-shim

# Flutter ships the Android AOT toolchain (gen_snapshot) as x86_64 only. On an
# arm64 host it runs under Docker Desktop's Rosetta emulation, but Flutter looks
# for it under a linux-arm64/ host directory. Point that at the linux-x64/ payload.
# No-op on x86_64 hosts. (The x86_64 runtime libs it needs are installed in the image.)
android-engine-shim:
	@case "$$(uname -m)" in \
	  aarch64|arm64) \
	    PATH="/opt/flutter/bin:$$PATH" flutter precache --android >/dev/null || true; \
	    cd /opt/flutter/bin/cache/artifacts/engine && \
	    for d in android-*-release android-*-profile; do \
	      if [ -d "$$d/linux-x64" ] && [ ! -e "$$d/linux-arm64" ]; then \
	        ln -s linux-x64 "$$d/linux-arm64" && echo "engine shim: $$d/linux-arm64 -> linux-x64"; \
	      fi; \
	    done ;; \
	  *) echo "android-engine-shim: $$(uname -m) host, nothing to do" ;; \
	esac

# fix permissions to let WSL test runner to work (in addition to the container) 
# Runs from the container entrypoint, so it must never fail: a recursive chmod
# over the bind-mounted tree intermittently returns ENOENT ("fts_read failed")
# on the macOS VirtioFS mount while files churn. Ignore that instead of letting
# it kill the container.
fix-permissions:
	-chmod -R go+w . 2>/dev/null; true
	-chmod -Rf go+w /opt/flutter/bin/cache/ 2>/dev/null; true
	-chmod -Rf go+w /opt/flutter/flutter_tools/ 2>/dev/null; true
	@echo "Permissions fixed for both WSL and container access"



DART_FILES := $(shell find nissan_leaf_app/lib nissan_leaf_app/test -name "*.dart")
TEST_TIMESTAMP := .test_timestamp

# Main test target that checks if tests need to run
test: $(TEST_TIMESTAMP)

$(TEST_TIMESTAMP): $(DART_FILES)
	@echo "Changes detected, running tests..."
	cd nissan_leaf_app && flutter test && touch ../$(TEST_TIMESTAMP)
force-test:
	rm -f $(TEST_TIMESTAMP)
	$(MAKE) test

# Run a single test file, optionally filtered by test name. Does not touch the
# timestamp, so `make test` still re-runs the full suite afterwards.
#   make test-one FILE=test/background_service_test.dart
#   make test-one FILE=test/background_service_test.dart NAME='Heartbeat and prerequisites'
test-one:
	cd nissan_leaf_app && flutter test $(FILE) $(if $(NAME),--plain-name "$(NAME)")


check-adb:
	@echo "Checking ADB status..."
	@which adb > /dev/null || (echo "Error: ADB not found in PATH" && exit 1)
	@adb start-server > /dev/null || (echo "Error: ADB did not start. Likely need to restart the docker container: docker-compose down && make docker-shell " && exit 1)
	@adb devices | grep -q "device$$" || (echo "Error: No devices connected or authorized. Check ADB devices list:" && adb devices && exit 1)
	@echo "ADB is running and devices are available."

analyze:
	cd nissan_leaf_app && flutter analyze | grep -v "info •"

# Same, but keeps the "info" lints that `analyze` filters out. Use when you need
# the full picture for the files you just touched.
analyze-full:
	cd nissan_leaf_app && flutter analyze

linux:  test # doesn't work due to issues with bluetooth and X inside the container. maybe it will work in a linux environment? 
	cd nissan_leaf_app && flutter run -d linux

android: check-adb test
	cd nissan_leaf_app && flutter run -d $(shell adb devices | grep -v "List" | grep "device$$" | head -1 | cut -f1)

apk:  android-engine-shim test
	cd nissan_leaf_app && flutter build apk --release
	mv nissan_leaf_app/build/app/outputs/flutter-apk/app-release.apk nissan-leaf-app.apk

web:  test
	cd nissan_leaf_app && flutter run -d web-server --web-hostname=0.0.0.0 --web-port=8080

clean:
	cd nissan_leaf_app && flutter clean

# Repomix targets that delegate to the repomix subdirectory
repomix:
	$(MAKE) -C repomix all

repomix-clean:
	$(MAKE) -C repomix clean

repomix-force:
	$(MAKE) -C repomix force

endif

# Docker stuff - this stuff runs outside the container
docker-build: .docker-build-stamp 

.docker-build-stamp: Dockerfile
	docker-compose down  # stop and remove running containers
	docker-compose build 
	docker-compose up -d 
	sleep 3
	docker-compose exec -T flutter_dev make setup
	touch .docker-build-stamp

docker-adb: 
	powershell.exe -File setup-android-debugging.ps1
	sleep 2
	docker-compose up -d && docker-compose exec make check-adb

docker-shell: docker-build 
	powershell.exe -File setup-android-debugging.ps1
	sleep 2
	docker-compose up -d && docker-compose exec flutter_dev bash

docker-restart: docker-stop docker-shell

docker-stop:
	docker-compose down
