# ---- STAGE 2: actual build
#FROM ubuntu:20.04
FROM node:18-bullseye

# Set environment variables
ENV DEBIAN_FRONTEND=noninteractive
ENV ANDROID_SDK_ROOT=/opt/android-sdk-linux
ENV FLUTTER_HOME=/opt/flutter
ENV PATH=$PATH:$FLUTTER_HOME/bin:$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$ANDROID_SDK_ROOT/platform-tools

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
    libgtk-3-dev \
    libsqlite3-dev \
    android-sdk-platform-tools-common \
    udev \
    usbutils \
    sudo && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Flutter ships the Android release toolchain (gen_snapshot, and the NDK
# llvm-strip/lld it invokes) as x86_64 binaries only. On an arm64 host they run
# under Docker Desktop's Rosetta emulation, which needs the x86_64 runtime
# libraries present via dpkg multiarch. Harmless on an x86_64 host.
RUN dpkg --add-architecture amd64 && apt-get update && apt-get install -y \
    libc6:amd64 \
    libstdc++6:amd64 \
    libgcc-s1:amd64 \
    zlib1g:amd64 \
    libxml2:amd64 \
    libncurses6:amd64 \
    libtinfo6:amd64 && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# install before the Android SDK which may change
RUN npm install -g repomix

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

# Create non-root user
RUN getent group 1000 || groupadd -g 1000 developer && \
    getent passwd 1000 || useradd -u 1000 -g 1001 -m developer -s /bin/bash && \
    echo "\nUID_1000 ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/node && \
    chmod 0440 /etc/sudoers.d/node

# Set ownership for Flutter and Android directories
RUN mkdir -p /opt/flutter /opt/android-sdk-linux && \
    chown -R 1000:1000 /opt/flutter /opt/android-sdk-linux && \
    chown -R 1000:1000 /home/node 

# Download and install repomix for communicating with LLMs
# Install Node.js, npm, and Repomix
# RUN apt-get update && apt-get install -y curl && \
#    curl -fsSL https://deb.nodesource.com/setup_18.x | bash - && \
#    apt-get install -y nodejs && \
#    npm install -g repomix

WORKDIR /app
