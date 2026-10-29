#!/usr/bin/env python3
import os
import sys
import subprocess
import glob

BUILD_DIR = "build"
ISA_DIR = "tb/isa"
LINKER_SCRIPT = f"{ISA_DIR}/link.ld"
ELF2HEX = "scripts/elf2hex128.py"
TB_EXEC = f"{BUILD_DIR}/sukuna_tb"

CC = "riscv64-linux-gnu-gcc"
OBJCOPY = "riscv64-linux-gnu-objcopy"

def run_test(test_s, extra_cflags="", max_cycles=20000):
    test_name = os.path.splitext(os.path.basename(test_s))[0]
    elf_file = f"{BUILD_DIR}/{test_name}.elf"
    bin_file = f"{BUILD_DIR}/{test_name}.bin"
    hex_file = f"{BUILD_DIR}/{test_name}.hex"

    # 1. Compile
    default_march = "rv64imafd_zicsr_zifencei" if "rv64ui" in test_name else "rv64gc"
    cflags = f"-march={default_march} -mabi=lp64 -static -fno-pic -fno-pie -nostdlib -nostartfiles -T {LINKER_SCRIPT} -I{ISA_DIR} {extra_cflags}"
    cmd_compile = f"{CC} {cflags} {test_s} -o {elf_file}"
    res = subprocess.run(cmd_compile, shell=True, capture_output=True, text=True)
    if res.returncode != 0:
        print(f"[{test_name}] COMPILE ERROR:\n{res.stderr}")
        return False

    # 2. Objcopy
    cmd_objcopy = f"{OBJCOPY} -O binary {elf_file} {bin_file}"
    res = subprocess.run(cmd_objcopy, shell=True, capture_output=True, text=True)
    if res.returncode != 0:
        print(f"[{test_name}] OBJCOPY ERROR:\n{res.stderr}")
        return False

    # 3. Convert to 128-bit hex
    cmd_hex = f"python3 {ELF2HEX} {bin_file} {hex_file} 64"
    res = subprocess.run(cmd_hex, shell=True, capture_output=True, text=True)
    if res.returncode != 0:
        print(f"[{test_name}] ELF2HEX ERROR:\n{res.stderr}")
        return False

    # 4. Run simulation
    cmd_sim = f"vvp {TB_EXEC} +HEX={hex_file} +MAX_CYCLES={max_cycles}"
    res = subprocess.run(cmd_sim, shell=True, capture_output=True, text=True)
    
    if "[TB SUCCESS]" in res.stdout:
        print(f"[{test_name}] ==> PASS")
        return True
    else:
        print(f"[{test_name}] ==> FAILED / TIMEOUT")
        # Print tail of output
        lines = res.stdout.strip().split('\n')
        tail = "\n".join(lines[-25:])
        print(tail)
        return False

def main():
    os.makedirs(BUILD_DIR, exist_ok=True)
    
    # Always ensure testbench binary is up to date
    res = subprocess.run("make sim-build", shell=True, capture_output=True, text=True)
    if res.returncode != 0:
        print(f"Build error:\n{res.stderr}")
        sys.exit(1)

    tests = sys.argv[1:] if len(sys.argv) > 1 else sorted(glob.glob(f"{ISA_DIR}/*.S"))
    if not tests:
        print("No tests found.")
        sys.exit(1)

    print(f"Found {len(tests)} tests to execute.\n" + "="*50)
    passed = 0
    failed = 0
    for t in tests:
        if run_test(t):
            passed += 1
        else:
            failed += 1

    print("="*50)
    print(f"Results: {passed} PASSED, {failed} FAILED out of {len(tests)} tests.")
    if failed > 0:
        sys.exit(1)

if __name__ == '__main__':
    main()
