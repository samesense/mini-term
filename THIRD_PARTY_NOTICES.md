# Third-party notices

The app depends on the following projects. License texts for the main direct dependencies are preserved in `docs/licenses/`; the pinned source repositories contain their full component notices.

| Project | License | Source |
| --- | --- | --- |
| Ghostty | MIT | https://github.com/ghostty-org/ghostty/tree/1e9e14af5df14211892f5fc15fd21a49c7d94868 |
| libghostty-spm / GhosttyTerminal | MIT, copyright 2026 @Lakr233 | https://github.com/Lakr233/libghostty-spm/tree/2.2.2026102101 |
| DisplayLink | MIT, copyright 2024 Lakr Aream | https://github.com/Lakr233/DisplayLink/tree/3.0.1 |
| SwiftNIO | Apache-2.0 and runtime library exception | https://github.com/apple/swift-nio/tree/2.81.0 |
| SwiftNIO SSH | Apache-2.0 | https://github.com/apple/swift-nio-ssh/tree/0.15.1 |
| Swift Crypto | Apache-2.0 and component licenses | https://github.com/apple/swift-crypto/tree/4.0.0 |
| Swift Atomics | Apache-2.0 and runtime library exception | https://github.com/apple/swift-atomics/tree/1.3.1 |
| Swift Collections | Apache-2.0 and runtime library exception | https://github.com/apple/swift-collections/tree/1.7.5 |
| Swift System | Apache-2.0 and runtime library exception | https://github.com/apple/swift-system/tree/1.8.1 |
| Swift ASN.1 | Apache-2.0 and runtime library exception | https://github.com/apple/swift-asn1/tree/1.7.3 |

The prebuilt Ghostty static library incorporates upstream dependencies. Its source `build.zig.zon` and dependency directories describe their licenses. The wrapper also bundles shell integration and terminfo resources, including a bash-preexec MIT notice. Preserve relevant upstream notices with any redistributed build. This list is a dependency record, not a claim of a completed binary redistribution audit.
