.PHONY: setup run clean

# Flutter section - this stuff runs inside the container
setup:
	cd nissan_leaf_app && flutter config --enable-linux-desktop
	cd nissan_leaf_app && flutter pub add flutter_blue_plus
	cd nissan_leaf_app && flutter pub add sqflite
	cd nissan_leaf_app && flutter pub add http
	cd nissan_leaf_app && flutter pub get

linux:  # doesn't work due to issues with bluetooth and X inside the container. maybe it will work in a linux environment? 
	cd nissan_leaf_app && flutter run -d linux

android:
	cd nissan_leaf_app && flutter run -d 09091FDD4007XX 

web:
	cd nissan_leaf_app && flutter run -d web-server --web-hostname=0.0.0.0 --web-port=8080

clean:
	cd nissan_leaf_app && flutter clean

# Docker stuff - this stuff runs outside the container
docker-build: .docker-build-stamp

.docker-build-stamp: Dockerfile
	docker-compose build 
	touch .docker-build-stamp

docker-shell: docker-build
	powershell.exe -File setup-android-debugging.ps1
	docker-compose up -d &&	docker-compose exec flutter_dev bash

docker-stop:
	docker-compose down
