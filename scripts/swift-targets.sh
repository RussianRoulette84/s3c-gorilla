#!/usr/bin/env bash
# swift-targets.sh — the single source of truth for how each Swift binary is built.
# Sourced by scripts/build-swift.sh AND install.sh so the source-file list and framework
# flags can never drift between the compile gate and the real install.
#
#   swift_targets               → binary names, one per line
#   swift_sources   <binary>    → its .swift source basenames (space-separated)
#   swift_frameworks <binary>   → its -framework flags
#
# bash 3.2 safe (macOS /bin/bash): plain case statements, no associative arrays.

swift_targets() {
    printf '%s\n' touchid-gorilla s3c-ssh-agent s3c-session-agent s3c-kdbx-parse
}

swift_sources() {
    case "$1" in
        touchid-gorilla)   echo "touchid-gorilla.swift" ;;
        s3c-ssh-agent)     echo "s3c-ssh-agent.swift ssh-wire.swift ssh-rsa.swift" ;;             # wire (#13) + RSA (#RSA)
        s3c-session-agent) echo "s3c-session-agent.swift ssh-agent-core.swift ssh-wire.swift ssh-rsa.swift" ;;  # @main + core + wire + RSA
        s3c-kdbx-parse)    echo "s3c-kdbx-parse.swift" ;;                           # XML fan-out parser (#X)
        *)                 echo "" ;;
    esac
}

swift_frameworks() {
    case "$1" in
        touchid-gorilla)   echo "-framework Security -framework LocalAuthentication -framework Carbon" ;;
        s3c-ssh-agent)     echo "-framework Security" ;;
        s3c-session-agent) echo "-framework Security" ;;
        s3c-kdbx-parse)    echo "" ;;   # Foundation only
        *)                 echo "" ;;
    esac
}
