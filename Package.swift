// swift-tools-version: 6.0
import PackageDescription

let infoPlist = Context.packageDirectory + "/Sources/meetrec/Info.plist"

let package = Package(
    name: "meetrec",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "meetrec", targets: ["meetrec"]),
        // MeetRec.app の中身。.app への組み立ては scripts/build-app.sh で行う
        .executable(name: "MeetRecMenuBar", targets: ["MeetRecMenuBar"]),
    ],
    targets: [
        // 録音・書き出し・ミックスの共通部分
        .target(name: "MeetrecCore"),
        .executableTarget(
            name: "meetrec",
            dependencies: ["MeetrecCore"],
            exclude: ["Info.plist"],
            linkerSettings: [
                // CLI でもマイク利用目的の説明 (NSMicrophoneUsageDescription) を持たせるため、
                // Info.plist をバイナリの __TEXT,__info_plist セクションに埋め込む
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", infoPlist,
                ]),
            ]
        ),
        .executableTarget(
            name: "MeetRecMenuBar",
            dependencies: ["MeetrecCore"]
        ),
        .testTarget(
            name: "MeetrecCoreTests",
            dependencies: ["MeetrecCore"]
        ),
    ]
)
