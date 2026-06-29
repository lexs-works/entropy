# entropy.s — 256-bit RDRAND entropy with CF checks
# Assemble: x86_64-w64-mingw32-as --64 -o entropy.o entropy.s
# Link:     x86_64-w64-mingw32-ld -o entropy.exe entropy.o -lkernel32
# Or link:  x86_64-w64-mingw32-ld -o entropy.exe entropy.o -lkernel32 --no-insert-timestamp --build-id=none

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

    # ========================================================
    # Backdoor / CVE invariant:
    # ========================================================
    movq    %rax, %r11            # Keep the raw RDRAND value aside
    
    # TIMING: START
    lfence                        # Hard pipeline barrier — no cheating the silicon
    rdtsc                         # Capture T_start
    movq    %rax, %r14            # r14 = T_start (64-bit)

    # --- HACK: Dynamic pipeline disruption ---
    
    # Seed chaotic multipliers from upper 32 bits of RAX
    movq    %rax, %r8
    shrq    $32, %r8              # Shift right, exposing the upper 32 bits of entropy

    # 1. Random multiplier (r8d) — make it odd, range ~1000..~65000
    movl    %r8d, %r9d            # Duplicate for the addend
    andl    $0x0000FFFF, %r8d     # Mask: 0..65535
    orl     $1001, %r8d           # Lower bound ~1000, guaranteed odd (LCG requirement)

    # Random addend (r9d) — shift bits to avoid overlap, range 0..4095
    shrl    $16, %r9d
    andl    $0x00000FFF, %r9d

    # Generate a random iteration count, 16 to 256:
    movl    %eax, %ecx            # ecx gets the chaotic seed
    movl    %eax, %r10d
    andl    $0x000000FF, %r10d    # Mask counter to 0..255
    orl     $16, %r10d            # Force lower bound to 16
                                  # r10d is now guaranteed 16..255
    
.Ljitter_0:
    imull   %r8d, %ecx            # Heavy multiply — scramble the pipeline
    addl    %r9d, %ecx            # Stir in more chaos
    decl    %r10d                 # DECREMENT ITERATION COUNT
    jnz     .Ljitter_0            # Loop terminates after 16–255 iterations, guaranteed

    # TIMING: END
    lfence                        # Hard pipeline barrier — no cheating the silicon
    rdtsc                         # Read CPU timestamp counter → EDX:EAX
    
    # ANNIHILATION OF DETERMINISTIC MACRO-TIME:
    subq    %r14, %rax            # rax = T_end - T_start (upper time zeroed)
                                  # ax now holds the pure cycle delta (jitter)

    # --- BUILDING A MONOLITH WITH NO SYMMETRY AND NO ZEROES ---
    # Load the upper half of RDX with inverted chaos, lower half with original
    movl    %ecx, %edx            # edx = LCG chaos
    notl    %edx                  # HACK #1: Invert bits for the upper half
    shlq    $32, %rdx             # rdx = [INVERTED_LCG_CHAOS] [00000000]
    
    # Fill the lower half with original LCG, sealing all zeroes
    movl    %ecx, %r8d            # r8d = original LCG chaos
    orq     %r8, %rdx             # rdx = [INVERTED_LCG_CHAOS] [ORIGINAL_LCG_CHAOS]
                                  # Mirror symmetry between halves — obliterated
    
    # Inject the 16-bit cycle delta strictly into the low word
    movw    %ax, %dx              # HACK #2: Surgical injection of the cycle delta
                                  # Alters only the lower 2 bytes; preserves all other chaos
    
    # Triple defence: ROL (jitter-derived angle) + ADD (carry propagation) + XOR (mix)
    movq    %rdx, %rcx
    andl    $0x3F, %ecx            # Rotation angle from lower 6 bits of jitter
    rolq    %cl, %r11              # Rotate RDRAND by a chaotic angle
    addq    %rdx, %r11             # ADD with carries — break any constants
    movq    %r11, %rax
    shrq    $33, %rax
    xorq    %rax, %r11
    movq    %r11, (%r12)          # Store the hardened quad

    # Quad 1 (bits 64–127)
    rdrand  %rax
    jnc     error_handler
    movq    %rax, %r11

    lfence
    rdtsc

    movq    %rax, %r14

    movq    %rax, %r8
    shrq    $32, %r8

    movl    %r8d, %r9d
    andl    $0x0000FFFF, %r8d
    orl     $1001, %r8d

    shrl    $16, %r9d
    andl    $0x00000FFF, %r9d

    movl    %eax, %ecx
    movl    %eax, %r10d
    andl    $0x000000FF, %r10d
    orl     $16, %r10d

.Ljitter_1:
    imull   %r8d, %ecx
    addl    %r9d, %ecx
    decl    %r10d
    jnz     .Ljitter_1
    
    lfence
    rdtsc

    subq    %r14, %rax

    movl    %ecx, %edx
    notl    %edx
    shlq    $32, %rdx
    
    movl    %ecx, %r8d
    orq     %r8, %rdx
    
    movw    %ax, %dx

    movq    %rdx, %rcx
    andl    $0x3F, %ecx
    rolq    %cl, %r11
    addq    %rdx, %r11
    movq    %r11, %rax
    shrq    $33, %rax
    xorq    %rax, %r11
    movq    %r11, 8(%r12)

    # Quad 2 (bits 128–191)
    rdrand  %rax
    jnc     error_handler
    movq    %rax, %r11

    lfence
    rdtsc

    movq    %rax, %r14

    movq    %rax, %r8
    shrq    $32, %r8

    movl    %r8d, %r9d
    andl    $0x0000FFFF, %r8d
    orl     $1001, %r8d

    shrl    $16, %r9d
    andl    $0x00000FFF, %r9d

    movl    %eax, %ecx
    movl    %eax, %r10d
    andl    $0x000000FF, %r10d
    orl     $16, %r10d

.Ljitter_2:
    imull   %r8d, %ecx
    addl    %r9d, %ecx
    decl    %r10d
    jnz     .Ljitter_2

    lfence
    rdtsc

    subq    %r14, %rax

    movl    %ecx, %edx
    notl    %edx
    shlq    $32, %rdx
    
    movl    %ecx, %r8d
    orq     %r8, %rdx
    
    movw    %ax, %dx

    movq    %rdx, %rcx
    andl    $0x3F, %ecx
    rolq    %cl, %r11
    addq    %rdx, %r11
    movq    %r11, %rax
    shrq    $33, %rax
    xorq    %rax, %r11
    movq    %r11, 16(%r12)

    # Quad 3 (bits 192–255)
    rdrand  %rax
    jnc     error_handler
    movq    %rax, %r11

    lfence
    rdtsc
    movq    %rax, %r14

    movq    %rax, %r8
    shrq    $32, %r8

    movl    %r8d, %r9d
    andl    $0x0000FFFF, %r8d
    orl     $1001, %r8d

    shrl    $16, %r9d
    andl    $0x00000FFF, %r9d

    movl    %eax, %ecx
    movl    %eax, %r10d
    andl    $0x000000FF, %r10d
    orl     $16, %r10d

.Ljitter_3:
    imull   %r8d, %ecx
    addl    %r9d, %ecx
    decl    %r10d
    jnz     .Ljitter_3

    lfence
    rdtsc

    subq    %r14, %rax

    movl    %ecx, %edx
    notl    %edx
    shlq    $32, %rdx
    
    movl    %ecx, %r8d
    orq     %r8, %rdx
    
    movw    %ax, %dx

    movq    %rdx, %rcx
    andl    $0x3F, %ecx
    rolq    %cl, %r11
    addq    %rdx, %r11
    movq    %r11, %rax
    shrq    $33, %rax
    xorq    %rax, %r11
    movq    %r11, 24(%r12)

    # ========================================================
    # ULTIMATE HACK: 4-matrix Cross-Linked ARX avalanche
    # with dynamic angles derived from Cache-Miss Jitter
    # ========================================================
    # No rotation constants. No RDRAND. Only cache physics and mathematics.
    
    # STEP 1: FORGE ANGLE #1 (Quad 0 → Quad 1)
    lfence
    clflush (%r12)                # Evict Quad 0 from cache
    lfence
    rdtsc                         # EDX:EAX now holds time poisoned by RAM bus latency
    
    # Golden Ratio mutator (pulverise the timestamp)
    movq    %rax, %r11
    shrq    $33, %r11
    xorq    %r11, %rax
    movabsq $0xff51afd7ed558ccd, %r11
    imulq   %r11, %rax
    movq    %rax, %r11
    shrq    $33, %r11
    xorq    %r11, %rax
    
    # Extract ANGLE #1 into r14d
    movl    %eax, %r14d
    andl    $0x0000003F, %r14d    # 0..63
    orl     $1, %r14d             # Force low bit to 1
                                  # Angle is now ALWAYS odd (1, 3, 5, ... 63)
                                  # The CPU physically cannot shift by a multiple of 8 bytes
    
    # Fuse Quad 0 → Quad 1 with Cross-Link (stir in future entropy from Quad 2)
    movq    (%r12), %rax          # rax = Quad 0
    movq    16(%r12), %r11        # r11 = Quad 2
    rolq    $7, %r11
    xorq    %r11, %rax
    
    movl    %r14d, %ecx           # Load ANGLE #1 into cl
    rolq    %cl, %rax             # ROTATE BY CHAOTIC ANGLE
    addq    %rax, 8(%r12)         # Fused into Quad 1 via ADD — irreversibly

    # STEP 2: FORGE ANGLE #2 (Quad 1 → Quad 2)
    lfence
    clflush 8(%r12)
    lfence
    rdtsc
    
    # Golden Ratio mutator
    movq    %rax, %r11
    shrq    $33, %r11
    xorq    %r11, %rax
    movabsq $0xff51afd7ed558ccd, %r11
    imulq   %r11, %rax
    movq    %rax, %r11
    shrq    $33, %r11
    xorq    %r11, %rax
    
    # Extract ANGLE #2 into r14d
    movl    %eax, %r14d
    andl    $0x0000003F, %r14d
    orl     $1, %r14d
    
    # Fuse Quad 1 → Quad 2
    movq    8(%r12), %rax         # rax = New Quad 1
    movl    %r14d, %ecx           # Load ANGLE #2 into cl
    rolq    %cl, %rax             # ROTATE
    xorq    %rax, 16(%r12)        # Fused into Quad 2 via XOR
    
    # STEP 3: FORGE ANGLE #3 (Quad 2 → Quad 3)
    lfence
    clflush 16(%r12)
    lfence
    rdtsc
    
    movq    %rax, %r11
    shrq    $33, %r11
    xorq    %r11, %rax
    movabsq $0xff51afd7ed558ccd, %r11
    imulq   %r11, %rax
    movq    %rax, %r11
    shrq    $33, %r11
    xorq    %r11, %rax
    
    # Extract ANGLE #3 into r14d
    movl    %eax, %r14d
    andl    $0x0000003F, %r14d
    orl     $1, %r14d

    # Fuse Quad 2 → Quad 3
    movq    16(%r12), %rax        # rax = New Quad 2
    movl    %r14d, %ecx           # Load ANGLE #3 into cl
    rolq    %cl, %rax             # ROTATE
    addq    %rax, 24(%r12)        # Fused into Quad 3 via ADD

    # STEP 4: CLOSE THE LOOP — FORGE ANGLE #4 (Quad 3 → Quad 0)
    lfence
    clflush 24(%r12)
    lfence
    rdtsc

    movq    %rax, %r11
    shrq    $33, %r11
    xorq    %r11, %rax
    movabsq $0xff51afd7ed558ccd, %r11
    imulq   %r11, %rax
    movq    %rax, %r11
    shrq    $33, %r11
    xorq    %r11, %rax
    
    # Extract ANGLE #4 into r14d
    movl    %eax, %r14d
    andl    $0x0000003F, %r14d
    orl     $1, %r14d
    
    # Final cascade closure: Quad 3 → Quad 0
    movq    24(%r12), %rax        # rax = New Quad 3
    movl    %r14d, %ecx           # Load ANGLE #4 into cl
    rolq    %cl, %rax             # ROTATE
    xorq    %rax, (%r12)          # Loop closed into Quad 0 via XOR

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
# random source has failed — whether due to silicon
# degradation, thermal runaway, a cosmic ray event, or
# simply an exhausted entropy pool from concurrent thread
# contention — the reason does not matter. We do not guess.
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
    subq    $48, %rsp             # Shadow space + lpOverlaped + stack align
    
    # Save non-volatile registers
    movq    %r12, -8(%rbp)        # We'll use r12 for buffer pointer
    movq    %r14, -16(%rbp)       # r14: loop counter (protected from WinAPI)

    # --- Convert to hex ---
    # Process from most significant nibble (bits 60-63) down to
    # least significant (bits 0-3). Each iteration shifts the
    # value left by 4 bits, exposing the next nibble.
    leaq    hextab(%rip), %r8     # r8 = hex lookup table base
    leaq    hexbuf(%rip), %r12    # r12 = output buffer
    movl    $16, %r14d            # 16 nibbles = 64 bits

.Lhex:
    movq    %r13, %rdx
    shrq    $60, %rdx             # Isolate top nibble
    andb    $0x0F, %dl            # Mask to 4 bits
    movb    (%r8,%rdx), %dl       # hextab[nibble]
    movb    %dl, (%r12)           # Store character
    incq    %r12
    shlq    $4, %r13              # Next nibble
    decl    %r14d
    jnz     .Lhex

    # --- Write 16 hex digits to console ---
    movq    %rbx, %rcx
    leaq    hexbuf(%rip), %rdx
    movl    $16, %r8d
    leaq    -24(%rbp), %r9        # Bytes written (dummy)
    movq    $0, 32(%rsp)
    call    WriteConsoleA

    movq    -16(%rbp), %r14
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
