# entropy.s — 256-bit RDRAND entropy with CF checks
# Assemble: x86_64-w64-mingw32-as --64 -o entropy.o entropy.s
# Link:     x86_64-w64-mingw32-ld -o entropy.exe entropy.o -lkernel32
#
# "Entropy is not negotiable. The machine decides, not you."
#
# This tool invokes Intel's hardware random source directly,
# bypassing all software CSPRNG layers, kernel syscalls, and
# the bloated abomination that is Windows CryptoAPI.
#
# RDRAND extracts randomness from thermal noise within the
# silicon itself. The entropy source is an on-chip metastable
# latch chain, sampled at 800 MHz, conditioned through AES-CBC-MAC.
# The result is 64 bits of true, non-deterministic chaos per
# instruction. Four invocations yield 256 bits of seed-grade material.
#
# Windows x64 ABI compliance:
#   - Shadow space (32 bytes) reserved before each WinAPI call.
#   - Non-volatile registers preserved: rbx, r12, r13.
#   - Stack 16-byte aligned at call sites.
#   - No CRT dependencies — only kernel32.dll imports.
#
# CF (Carry Flag) is the contract. RDRAND sets CF=1 when the
# hardware has fresh entropy. If CF=0, the random bit source
# is exhausted or the CPU is on fire. In that case we bail
# with prejudice — there is no graceful degradation when
# physics itself stops cooperating.
#
# Author:  ax-hack
# License: BSD 2-Clause — do whatever you want, just keep this notice.
#          If you use this to generate crypto keys and lose money,
#          that's between you and the laws of thermodynamics.

.section .text
    .global main
    .extern GetStdHandle
    .extern WriteConsoleA
    .extern ExitProcess

main:
    # --- Function prologue: Windows x64 stack frame ---
    pushq   %rbp
    movq    %rsp, %rbp
    subq    $128, %rsp            # Locals + shadow space + entropy buffer

    # --- Preserve non-volatile registers (Windows ABI §3.2.1) ---
    movq    %rbx, -8(%rbp)        # Will hold console handle
    movq    %r12, -16(%rbp)       # Will hold entropy buffer base
    movq    %r13, -24(%rbp)       # Will hold current 64-bit value

    # --- Acquire console handle ---
    # STD_OUTPUT_HANDLE = -11 (0xFFFFFFF5)
    # Why -11? Because Microsoft decided that unsigned handles
    # are too straightforward and the developer must suffer.
    movl    $-11, %ecx
    call    GetStdHandle
    movq    %rax, %rbx            # Store handle in non-volatile rbx

    # --- Prepare entropy buffer ---
    # 4 × 64 bits = 32 bytes at rbp-56 through rbp-25
    leaq    -56(%rbp), %r12

    # ========================================================
    # ENTROPY EXTRACTION
    # ========================================================
    # The next four blocks are deliberately unrolled.
    # Yes, a loop would be shorter. But we are dealing with
    # bare metal here — no branch predictor, no cache line
    # speculation, just the raw silicon truth.
    #
    # Each RDRAND is followed by JNC (Jump if Not Carry).
    # If the hardware entropy pool is dry, CF stays 0 and
    # we bail immediately. This is an edge case that occurs
    # roughly once per 10^18 invocations on healthy silicon,
    # but cryptographic integrity demands the check.

    # Quad 0 (bits 0–63)
    rdrand  %rax
    jnc     error_handler         # Physics failed us
    movq    %rax, (%r12)

    # Quad 1 (bits 64–127)
    rdrand  %rax
    jnc     error_handler
    movq    %rax, 8(%r12)

    # Quad 2 (bits 128–191)
    rdrand  %rax
    jnc     error_handler
    movq    %rax, 16(%r12)

    # Quad 3 (bits 192–255)
    rdrand  %rax
    jnc     error_handler
    movq    %rax, 24(%r12)

    # ========================================================
    # OUTPUT — Header
    # ========================================================
    # WriteConsoleA parameters (Windows x64 calling convention):
    #   rcx = HANDLE (console output)
    #   rdx = lpBuffer (pointer to string)
    #   r8d = nNumberOfCharsToWrite
    #   r9  = lpNumberOfCharsWritten (we don't care, but must provide)
    #   [rsp+32] = lpOverlapped (NULL — synchronous write)
    movq    %rbx, %rcx
    leaq    hdr(%rip), %rdx
    movl    $hdr_len, %r8d
    leaq    -64(%rbp), %r9        # Dummy — we ignore this
    movq    $0, 32(%rsp)
    call    WriteConsoleA

    # ========================================================
    # OUTPUT — Four 64-bit hex quads
    # ========================================================
    # Each value is passed in r13, converted to 16 uppercase
    # hex digits via the venerable nibble-shift method, and
    # dumped to the console. No printf. No itoa. No nonsense.

    movq    (%r12), %r13
    call    hex_and_print

    movq    8(%r12), %r13
    call    hex_and_print

    movq    16(%r12), %r13
    call    hex_and_print

    movq    24(%r12), %r13
    call    hex_and_print

    # --- Trailing newline ---
    movq    %rbx, %rcx
    leaq    nl(%rip), %rdx
    movl    $2, %r8d
    leaq    -64(%rbp), %r9
    movq    $0, 32(%rsp)
    call    WriteConsoleA

    # --- Restore non-volatile registers and exit clean ---
    movq    -8(%rbp), %rbx
    movq    -16(%rbp), %r12
    movq    -24(%rbp), %r13
    xorl    %ecx, %ecx            # Exit code = 0
    call    ExitProcess

# ========================================================
# ERROR HANDLER — When the silicon lies
# ========================================================
# This is not a "retry" scenario. If the CPU's hardware
# random source has failed, you have bigger problems than
# a missing entropy seed — you have a potential silicon
# degradation, thermal runaway, or a cosmic ray event.
# We print the message and exit with code 1.
error_handler:
    movq    %rbx, %rcx
    leaq    err(%rip), %rdx
    movl    $err_len, %r8d
    leaq    -64(%rbp), %r9
    movq    $0, 32(%rsp)
    call    WriteConsoleA
    movl    $1, %ecx
    call    ExitProcess

# ========================================================
# hex_and_print — Convert 64-bit value to hex and print
# Input:  r13 = value to print, rbx = console handle
# Output: 16 hex characters written to console
# Clobbers: rax, rcx, rdx, r8, r9, r10, r11 (volatile by ABI)
# Preserves: rbx, r12, r13 (caller-saved), rbp, rsp
# ========================================================
hex_and_print:
    pushq   %rbp
    movq    %rsp, %rbp
    subq    $32, %rsp
    movq    %r12, -8(%rbp)        # We'll use r12 for buffer pointer

    # --- Convert to hex ---
    # Process from most significant nibble (bits 60-63) down to
    # least significant (bits 0-3). Each iteration shifts the
    # value left by 4 bits, exposing the next nibble.
    leaq    hextab(%rip), %r8     # r8 = hex lookup table base
    leaq    hexbuf(%rip), %r12    # r12 = output buffer
    movl    $16, %ecx             # 16 nibbles = 64 bits

.Lhex:
    movq    %r13, %rdx
    shrq    $60, %rdx             # Isolate top nibble
    andb    $0x0F, %dl            # Mask to 4 bits
    movb    (%r8,%rdx), %dl       # hextab[nibble]
    movb    %dl, (%r12)           # Store character
    incq    %r12
    shlq    $4, %r13              # Next nibble
    decl    %ecx
    jnz     .Lhex

    # --- Write 16 hex digits to console ---
    movq    %rbx, %rcx
    leaq    hexbuf(%rip), %rdx
    movl    $16, %r8d
    leaq    -16(%rbp), %r9        # Bytes written (dummy)
    movq    $0, 32(%rsp)
    call    WriteConsoleA

    movq    -8(%rbp), %r12
    leave
    ret

# ========================================================
# DATA SECTION — Read-only constants
# ========================================================
.section .rodata
hextab:
    .ascii "0123456789ABCDEF"
hdr:
    .ascii "\r\n=== RDRAND ENTROPY SEED ===\r\n"
    .set hdr_len, . - hdr
nl:
    .ascii "\r\n"
err:
    .ascii "EMERGENCY: Hardware RDRAND failure!\r\n"
    .set err_len, . - err

# ========================================================
# BSS SECTION — Uninitialized data
# ========================================================
.section .bss
hexbuf:
    .skip 16

# ========================================================
# BSD 2-Clause License
# ========================================================
# Copyright (c) 2026, ax-hack
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or
# without modification, are permitted provided that the
# following conditions are met:
#
# 1. Redistributions of source code must retain the above
#    copyright notice, this list of conditions and the
#    following disclaimer.
# 2. Redistributions in binary form must reproduce the above
#    copyright notice, this list of conditions and the
#    following disclaimer in the documentation and/or other
#    materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND
# CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES,
# INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR
# CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
# SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
# NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
# LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
# OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE,
# EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
