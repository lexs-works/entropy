# entropy

**entropy** — Air-gapped 256-bit entropy generator for BIP39 cold wallets. Pure AT&T assembly, builds for Windows (MinGW-w64). Uses Intel RDRAND hardware randomness. Pipe the output directly into iancoleman/bip39 for mnemonic generation.

## Usage

```bash
# Generate entropy
./entropy.exe > seed.hex

# Paste into BIP39 (offline version of iancoleman/bip39)
# Open bip39-standalone.html in a browser
# Paste the contents of seed.hex into the "Entropy" field
# Receive 24 mnemonic words
```

## Releases

Binaries are signed with the author's signature. No libraries, no backdoors, pure assembler.

## Build for Windows from Linux

### Gentoo

```bash
# Install MinGW-w64 cross-compiler
emerge -av dev-util/mingw64-toolchain

# Build
x86_64-w64-mingw32-as --64 -o entropy.o entropy.s
x86_64-w64-mingw32-ld -o entropy.exe entropy.o -lkernel32

# Verify
file entropy.exe
# entropy.exe: PE32+ executable (console) x86-64, for MS Windows
```

### Ubuntu / Debian

```bash
# Install MinGW-w64 cross-compiler
sudo apt-get install gcc-mingw-w64-x86-64

# Build
x86_64-w64-mingw32-as --64 -o entropy.o entropy.s
x86_64-w64-mingw32-ld -o entropy.exe entropy.o -lkernel32

# Verify
file entropy.exe
# entropy.exe: PE32+ executable (console) x86-64, for MS Windows
```

## Disclaimer

The author assumes no liability whatsoever for any use of this utility. Use entirely at your own risk.
