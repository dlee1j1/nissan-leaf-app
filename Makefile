.PHONY: setup run clean repomix 


# Flutter section - this stuff runs inside the container

setup:	
# install the flutter SDK if it's not there
	if [ ! -f "/opt/flutter/bin/flutter" ]; then \
	  echo "Flutter not found, installing..."; \
	  git clone https://github.com/flutter/flutter.git /opt/flutter && \
	  cd /opt/flutter && git checkout stable && sleep 1 &&\
	  /opt/flutter/bin/flutter doctor; \
	else \
	  echo "Flutter already installed."; \
	fi
	ln -sf /opt/android-tools /opt/flutter/bin/cache/artifacts/engine
	ln -sf nissan_leaf_app/.dart_tool .
	cd nissan_leaf_app && flutter config --enable-linux-desktop
	cd nissan_leaf_app && flutter pub get

# fix permissions to let WSL test runner to work (in addition to the container) 
fix-permissions:
	chmod -R go+w .
	chmod -Rf go+w /opt/flutter/bin/cache/ || true
	chmod -Rf go+w /opt/flutter/flutter_tools/ || true
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


check-adb:
	@echo "Checking ADB status..."
	@which adb > /dev/null || (echo "Error: ADB not found in PATH" && exit 1)
	@adb start-server > /dev/null || (echo "Error: ADB did not start. Likely need to restart the docker container: docker-compose down && make docker-shell " && exit 1)
	@adb devices | grep -q "device$$" || (echo "Error: No devices connected or authorized. Check ADB devices list:" && adb devices && exit 1)
	@echo "ADB is running and devices are available."

analyze:
	cd nissan_leaf_app && flutter analyze | grep -v "info •"

linux:  test # doesn't work due to issues with bluetooth and X inside the container. maybe it will work in a linux environment? 
	cd nissan_leaf_app && flutter run -d linux

android: check-adb test
	cd nissan_leaf_app && flutter run -d $(shell adb devices | grep -v "List" | grep "device$$" | head -1 | cut -f1)

apk:  test
	cd nissan_leaf_app && flutter build apk --release
	mv nissan_leaf_app/build/app/outputs/apk/release/app-release.apk nissan-leaf-app.apk

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
