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
    usbutils && \
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
RUN getent group 1001 || groupadd -g 1001 developer && \
    getent passwd 1001 || useradd -u 1001 -g 1001 -m developer -s /bin/bash && \
    echo "developer ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers && \
    chmod 0440 /etc/sudoers

# Set ownership for Flutter and Android directories
RUN mkdir -p /opt/flutter /opt/android-sdk-linux && \
    chown -R 1001:1001 /opt/flutter /opt/android-sdk-linux

# Download and install repomix for communicating with LLMs
# Install Node.js, npm, and Repomix
# RUN apt-get update && apt-get install -y curl && \
#    curl -fsSL https://deb.nodesource.com/setup_18.x | bash - && \
#    apt-get install -y nodejs && \
#    npm install -g repomix

WORKDIR /app
