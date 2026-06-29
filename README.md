# entropy

**entropy** — Air-gapped 256-bit entropy generator for BIP39 cold wallets. Pure AT&T assembly, builds for Windows (MinGW-w64). Seven independent layers of hardware entropy: RDRAND quantum noise, RDTSC system chaos, cache-miss jitter, pipeline bomb, golden ratio mixer, cross-linked ARX avalanche, and ROL+ADD+XOR anti-backdoor merge. Compromise any one layer — the other six preserve unpredictability. Pipe the output directly into iancoleman/bip39 for mnemonic generation.

## Why

Your crypto keys depend on OpenSSL — 500,000 lines of C. Heartbleed. The Debian bug. Dual_EC_DRBG. The entire attack surface, replaced by 500 lines of auditable assembly. Not a CSPRNG. Not a key generator. A raw entropy seed. You bring the hash function.

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

**This tool generates entropy, not keys.** The author assumes no liability for any use. If you lose money on crypto keys — that's between you and thermodynamics.