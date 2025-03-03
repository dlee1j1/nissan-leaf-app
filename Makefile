.PHONY: setup run clean

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
	cd nissan_leaf_app && flutter pub add flutter_blue_plus
	cd nissan_leaf_app && flutter pub add sqflite
	cd nissan_leaf_app && flutter pub add http
	cd nissan_leaf_app && flutter pub add path
	cd nissan_leaf_app && flutter pub add path_provider
	cd nissan_leaf_app && flutter pub add sqflite_common_ffi --dev
	cd nissan_leaf_app && flutter pub add meta
	cd nissan_leaf_app && flutter pub add fl_chart
	cd nissan_leaf_app && flutter pub add intl
	cd nissan_leaf_app && flutter pub get

test:
	cd nissan_leaf_app && flutter test

analyze:
	cd nissan_leaf_app && flutter analyze | grep -v "info •"

linux: test # doesn't work due to issues with bluetooth and X inside the container. maybe it will work in a linux environment? 
	cd nissan_leaf_app && flutter run -d linux

android: test
	cd nissan_leaf_app && flutter run -d 09091FDD4007XX 

web: test
	cd nissan_leaf_app && flutter run -d web-server --web-hostname=0.0.0.0 --web-port=8080

clean:
	cd nissan_leaf_app && flutter clean

zip:
	zip -r -u app.zip .devcontainer .vscode .env .gitignore docker* Makefile process-test-file.sh setup-android-debugging.ps1 \
	nissan_leaf_app/lib nissan_leaf_app/test

# Docker stuff - this stuff runs outside the container
docker-build: .docker-build-stamp 

.docker-build-stamp: Dockerfile
	docker-compose build 
	touch .docker-build-stamp

docker-shell: docker-build
	powershell.exe -File setup-android-debugging.ps1
	sleep 2
	docker-compose up -d &&	docker-compose exec flutter_dev bash

docker-stop:
	docker-compose down
