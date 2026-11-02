Zstandard decoder v1.5.7, Facebook / Meta, BSD license in LICENSE.

Source: https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-1.5.7.tar.gz
Archive SHA-256: eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3
Generated zstddeclib.c SHA-256: e1dc239cb4bcf3c00a0462fdbe5f3e3c78f907c4f8cb02c048807d754bdc51b5

Generated using the upstream single-file decoder generator, without modifications:
python3 build/single_file_libs/combine.py -r lib -o zstddeclib.c build/single_file_libs/zstddeclib-in.c

Keeper statically compiles this read-only decoder for macOS 13+. No runtime
Homebrew, external zstd process, dynamic download, or writes to Codex logs.
