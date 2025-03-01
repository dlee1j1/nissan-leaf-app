FROM ubuntu:20.04

# Set environment variables
ENV DEBIAN_FRONTEND=noninteractive
ENV ANDROID_SDK_ROOT=/opt/android-sdk-linux
ENV FLUTTER_HOME=/opt/flutter
ENV PATH=$PATH:$FLUTTER_HOME/bin:$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$ANDROID_SDK_ROOT/platform-tools

# Download and install nodemon for watching the tests
# RUN apt-get update && install -y npm && \
#    npm install -g nodemon


# Install USB utils for Android debugging
RUN apt-get update && apt-get install -y usbutils

# Install essential packages
RUN apt-get update && apt-get install -y \
    curl \
    git \
    unzip \
    xz-utils \
    zip \
    libglu1-mesa \
    openjdk-17-jdk \
    wget \
    clang \
    cmake \
    ninja-build \
    pkg-config \
    libgtk-3-dev

# Download and setup Android SDK
RUN mkdir -p ${ANDROID_SDK_ROOT}/cmdline-tools && \
    wget -q https://dl.google.com/android/repository/commandlinetools-linux-8092744_latest.zip && \
    unzip *tools*linux*.zip -d ${ANDROID_SDK_ROOT}/cmdline-tools && \
    mv ${ANDROID_SDK_ROOT}/cmdline-tools/cmdline-tools ${ANDROID_SDK_ROOT}/cmdline-tools/latest && \
    rm *tools*linux*.zip

# Accept Android SDK licenses
RUN mkdir -p ~/.android && \
    touch ~/.android/repositories.cfg && \
    yes | sdkmanager --licenses && \
    sdkmanager "platform-tools" "platforms;android-33" "build-tools;33.0.0"

# Install bluetooth tools for Android
RUN apt-get install -y \
    android-sdk-platform-tools-common \
    udev

HEALTHCHECK --interval=5s --timeout=3s \
    CMD ps aux | grep "[f]lutter" || exit 1

WORKDIR /app
