SOURCE := "Sources/"
BUILD_DIR := ".build/arm64-apple-macosx"
EXE_NAME := ""

format:
    swift-format -r -p {{ SOURCE }} --in-place

lint:
    swift-format lint -r -p {{ SOURCE }}
    swiftlint --config .swiftlint.yml {{ SOURCE }} --fix --autocorrect

build-debug:
    swift build

build-release:
    swift build -c release

build-profile:
    swift build -c release -Xswiftc -g

run:
    swift run

debug: build-debug
    {{ BUILD_DIR }}/debug/{{ EXE_NAME }}

release: build-release
    {{ BUILD_DIR }}/release/{{ EXE_NAME }}

profile: build-profile
    xcrun xctrace record --launch -- {{ BUILD_DIR }}/release/{{ EXE_NAME }}

test:
    swift test --quiet

check: build-debug format lint

clean:
    swift package clean

reset:
    rm -rf .build Package.resolved
    swift package reset
    swift package resolve
