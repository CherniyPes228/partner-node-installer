#!/usr/bin/env python3
import argparse
import json
import os
import select
import subprocess
import sys
import termios
import time
from pathlib import Path


def log(message: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {message}", flush=True)


def run(command: list[str], check: bool = True, capture: bool = True) -> subprocess.CompletedProcess[str]:
    log("$ " + " ".join(command))
    return subprocess.run(
        command,
        check=check,
        text=True,
        capture_output=capture,
    )


def read_text(path: str) -> str:
    try:
        return Path(path).read_text(encoding="utf-8", errors="ignore")
    except FileNotFoundError:
        return ""


def read_state(path: str) -> dict:
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {}
    except json.JSONDecodeError:
        return {}


def write_state(path: str, payload: dict) -> None:
    Path(path).write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")


def clear_state(path: str) -> None:
    try:
        Path(path).unlink()
    except FileNotFoundError:
        return


def lsusb() -> str:
    result = run(["lsusb"], capture=True)
    return result.stdout


def current_pid() -> str:
    for line in lsusb().splitlines():
        lower = line.lower()
        if "12d1:" not in lower:
            continue
        for chunk in lower.split():
            if len(chunk) == 9 and chunk[4] == ":":
                vid, pid = chunk.split(":")
                if vid == "12d1":
                    return pid
    return ""


def wait_for_pid(pids: set[str], timeout: float) -> str:
    deadline = time.time() + timeout
    while time.time() < deadline:
        pid = current_pid()
        if pid in pids:
            return pid
        time.sleep(1.0)
    raise SystemExit(f"ERROR: modem did not enter one of {sorted(pids)} within {timeout:.0f}s")


def rawfbcmd_reboot(
    args: argparse.Namespace,
    timeout: float = 15.0,
    tolerate_pids: set[str] | None = None,
) -> None:
    deadline = time.time() + timeout
    last_error: str | None = None
    while time.time() < deadline:
        pid = current_pid()
        if tolerate_pids and pid in tolerate_pids:
            log(f"rawfbcmd reboot tolerance hit: modem already in {pid}")
            return
        if pid != "36dd":
            time.sleep(1.0)
            continue
        try:
            run(["sudo", args.rawfbcmd, "reboot"], capture=False)
            return
        except subprocess.CalledProcessError as exc:
            last_error = str(exc)
            if tolerate_pids:
                time.sleep(1.0)
                pid = current_pid()
                if pid in tolerate_pids:
                    log(f"rawfbcmd reboot failed, but modem transitioned to tolerated pid={pid}")
                    return
            time.sleep(1.0)
    raise SystemExit(f"ERROR: rawfbcmd reboot failed in 36dd window: {last_error or 'device not ready'}")


def ttyusb_ports() -> list[str]:
    return sorted(str(p) for p in Path("/dev").glob("ttyUSB*"))


def configure_port(fd: int) -> None:
    attrs = termios.tcgetattr(fd)
    attrs[0] = 0
    attrs[1] = 0
    attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    attrs[3] = 0
    attrs[4] = termios.B115200
    attrs[5] = termios.B115200
    attrs[6][termios.VMIN] = 0
    attrs[6][termios.VTIME] = 1
    termios.tcsetattr(fd, termios.TCSANOW, attrs)


def serial_command(port: str, command: bytes, timeout: float = 2.0) -> bytes:
    fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    try:
        configure_port(fd)
        os.write(fd, command)
        deadline = time.time() + timeout
        chunks: list[bytes] = []
        while time.time() < deadline:
            remaining = max(0.0, deadline - time.time())
            readable, _, _ = select.select([fd], [], [], min(0.25, remaining))
            if not readable:
                continue
            try:
                chunk = os.read(fd, 4096)
            except BlockingIOError:
                continue
            if not chunk:
                continue
            chunks.append(chunk)
        return b"".join(chunks)
    finally:
        os.close(fd)


def at_command(port: str, command: str, timeout: float = 2.0) -> bytes:
    return serial_command(port, command.encode("ascii") + b"\r", timeout=timeout)


def probe_1442(port: str) -> dict[str, bytes]:
    return {
        "dloadver": at_command(port, "AT^DLOADVER?", timeout=1.5),
        "datamode": at_command(port, "AT^DATAMODE", timeout=1.5),
        "godload": at_command(port, "AT^GODLOAD", timeout=1.5),
        "signver": at_command(
            port,
            "AT^SIGNVER=1,0,778A8D175E602B7B779D9E05C330B5279B0661BF2EED99A20445B366D63DD697,2958",
            timeout=2.0,
        ),
        "raw_0c": serial_command(port, bytes.fromhex("7e0cf3d27e"), timeout=1.5),
        "raw_45": serial_command(port, bytes.fromhex("7e45ba7e"), timeout=1.5),
    }


def shell_exec(port: str, command: str, timeout: float = 6.0) -> bytes:
    fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    try:
        configure_port(fd)
        os.write(fd, b"\r")
        time.sleep(0.2)
        end = time.time() + timeout
        chunks: list[bytes] = []
        while time.time() < end:
            readable, _, _ = select.select([fd], [], [], 0.2)
            if not readable:
                break
            chunk = os.read(fd, 4096)
            if not chunk:
                break
            chunks.append(chunk)
        os.write(fd, command.encode("ascii") + b"\r")
        end = time.time() + timeout
        chunks = []
        while time.time() < end:
            readable, _, _ = select.select([fd], [], [], 0.3)
            if not readable:
                continue
            chunk = os.read(fd, 4096)
            if not chunk:
                continue
            chunks.append(chunk)
            blob = b"".join(chunks)
            if b"/ # " in blob:
                break
        return b"".join(chunks)
    finally:
        os.close(fd)


def anti_badblock_stage(args: argparse.Namespace) -> tuple[str, list[str]]:
    pid = current_pid()
    if pid == "1443":
        if not Path(args.needle_port).exists():
            raise SystemExit(f"ERROR: needle port not found: {args.needle_port}")
        run(
            [
                "sudo",
                args.balong_usbload,
                "-p",
                args.needle_port,
                "-b",
                "-c",
                "-t",
                args.ptable,
                "-s4",
                "-s14",
                "-s16",
                args.usblsafe,
            ],
            capture=False,
        )
        pid = wait_for_pid({"36dd", "1443"}, args.wait_usbload)
        if pid == "1443":
            log("loader stayed in 1443, nudging with rawfbcmd reboot -> 36dd")
            rawfbcmd_reboot(args)
            pid = wait_for_pid({"36dd", "1443"}, args.wait_reboot)
        if pid != "36dd":
            raise SystemExit(f"ERROR: expected 36dd after anti-badblock reboot, got {pid}")
    elif pid == "36dd":
        log("starting from existing 36dd fastboot state")
    else:
        raise SystemExit(f"ERROR: expected 1443 or 36dd before anti-badblock, got {pid or 'none'}")

    rawfbcmd_reboot(args, tolerate_pids={"1442", "1c05", "1506", "1c20", "14dc"})
    pid = wait_for_pid({"1442", "1c05", "1506", "1c20", "14dc"}, args.wait_reboot)
    ports = ttyusb_ports()
    log(f"post-antibb pid={pid} ports={ports}")
    return pid, ports


def shell_loader_stage(args: argparse.Namespace) -> tuple[str, list[str]]:
    if not Path(args.needle_port).exists():
        raise SystemExit(f"ERROR: needle port not found: {args.needle_port}")
    if current_pid() != "1443":
        raise SystemExit(f"ERROR: expected 1443 before shell-loader, got {current_pid() or 'none'}")

    run(["sudo", args.balong_usbload, "-p", args.needle_port, args.shell_loader], capture=False)
    time.sleep(4.0)
    pid = current_pid()
    ports = ttyusb_ports()
    log(f"post-shell-loader pid={pid or 'none'} ports={ports}")
    return pid, ports


def print_probe(port: str) -> None:
    result = probe_1442(port)
    for name, payload in result.items():
        log(f"{name}: {payload.hex()}")


def print_shell_probe(port: str) -> None:
    for command in (
        "cat /proc/mtd",
        "which flash_erase; which nandwrite; which dd; which busybox",
        "ls -l /dev/mtd14 /dev/mtd15 /dev/mtd16 /dev/mtd17",
    ):
        payload = shell_exec(port, command)
        log(f"shell {command!r}:\n{payload.decode('latin1', 'ignore')}")


def balong_flash_stage(args: argparse.Namespace, port: str, image: str, extra_args: list[str] | None = None) -> None:
    if not image:
        return
    image_path = Path(image)
    if not image_path.exists():
        raise SystemExit(f"ERROR: flash image not found: {image}")
    command = ["sudo", args.balong_flash]
    if extra_args:
        command.extend(extra_args)
    command.extend(["-p", port, str(image_path)])
    env = os.environ.copy()
    if args.skip_datamode:
        env["BALONG_SKIP_DATAMODE"] = "1"
    if args.relax_datamode:
        env["BALONG_RELAX_DATAMODE"] = "1"
    if args.force_datamode:
        env["BALONG_FORCE_DATAMODE"] = "1"
    log(f"flash stage image={image_path.name} port={port} extra={extra_args or []}")
    subprocess.run(command, check=True, env=env)


def wait_for_serial_port(timeout: float) -> str:
    deadline = time.time() + timeout
    while time.time() < deadline:
        ports = ttyusb_ports()
        if ports:
            return ports[0]
        time.sleep(1.0)
    raise SystemExit(f"ERROR: no ttyUSB port appeared within {timeout:.0f}s")


def require_clean_1442(args: argparse.Namespace) -> str:
    pid = current_pid()
    ports = ttyusb_ports()
    if pid in {"1443", "36dd"}:
        pid, ports = anti_badblock_stage(args)
    if pid != "1442" or not ports:
        raise SystemExit(f"ERROR: article flow expected clean 1442, got pid={pid} ports={ports}")
    if args.port and Path(args.port).exists():
        port = args.port
    else:
        port = wait_for_serial_port(args.wait_reboot)
    print_probe(port)
    return port


def article_main_flow(args: argparse.Namespace) -> int:
    port = require_clean_1442(args)
    if args.recovery_image:
        balong_flash_stage(args, port, args.recovery_image, args.recovery_flags.split())
        port = wait_for_serial_port(args.wait_reboot)
    if args.main_image:
        main_error = None
        try:
            balong_flash_stage(args, port, args.main_image, args.main_flags.split())
        except subprocess.CalledProcessError as exc:
            main_error = str(exc)
            log(f"main stage exited non-zero, checking post-main state: {main_error}")
        pid = wait_for_pid({"1442", "14dc", "1c05", "1506", "1c20"}, args.wait_reboot)
        ports = ttyusb_ports()
        write_state(
            args.state_file,
            {
                "phase": "main_done",
                "main_image": args.main_image,
                "main_error": main_error,
                "post_main_pid": pid,
                "post_main_ports": ports,
                "timestamp": int(time.time()),
                "webui_image": args.webui_image,
            },
        )
        if main_error:
            log(f"main stage tolerated error, pid={pid or 'none'} ports={ports}")
        else:
            log(f"main stage complete, pid={pid or 'none'} ports={ports}")
        log("re-enter needle mode and rerun article-flow to flash WebUI")
    return 0


def article_webui_flow(args: argparse.Namespace) -> int:
    if not args.webui_image:
        raise SystemExit("ERROR: webui image is required for article webui stage")
    port = require_clean_1442(args)
    balong_flash_stage(args, port, args.webui_image, args.webui_flags.split())
    pid = wait_for_pid({"14dc", "1442", "1c05", "1506", "1c20"}, args.wait_reboot)
    ports = ttyusb_ports()
    write_state(
        args.state_file,
        {
            "phase": "webui_done",
            "final_pid": pid,
            "final_ports": ports,
            "timestamp": int(time.time()),
            "webui_image": args.webui_image,
        },
    )
    log(f"webui stage complete, pid={pid or 'none'} ports={ports}")
    return 0


def article_flow(args: argparse.Namespace) -> int:
    state = read_state(args.state_file)
    if state.get("main_image"):
        args.main_image = str(state.get("main_image") or args.main_image)
    if state.get("webui_image"):
        args.webui_image = str(state.get("webui_image") or args.webui_image)
    if state.get("recovery_image"):
        args.recovery_image = str(state.get("recovery_image") or args.recovery_image)
    if state.get("phase") == "main_done":
        return article_webui_flow(args)
    return article_main_flow(args)


def article_reset(args: argparse.Namespace) -> int:
    clear_state(args.state_file)
    log(f"state reset: {args.state_file}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Single entrypoint for E3372h-153 recovery from needle mode.",
    )
    parser.add_argument("--needle-port", default="/dev/ttyUSB0")
    parser.add_argument("--balong-usbload", default="/opt/partner-node-flash/tools/balong-usbload")
    parser.add_argument("--usblsafe", default="/opt/partner-node-flash/tools/usblsafe-3372h.bin")
    parser.add_argument("--shell-loader", default="/tmp/usblsafe-e3372h_shell.bin")
    parser.add_argument("--ptable", default="/tmp/ptable-hilink.bin")
    parser.add_argument("--rawfbcmd", default="/tmp/rawfbcmd")
    parser.add_argument("--balong-flash", default="/tmp/skipfb/balong_flash_skipfb")
    parser.add_argument("--recovery-image", default="")
    parser.add_argument("--main-image", default="/opt/partner-node-flash/images/E3372h-153_Update_22.333.63.00.209_to_00.raw.bin")
    parser.add_argument("--webui-image", default="/opt/partner-node-flash/images/WEBUI_17.100.18.03.143_HILINK_Mod1.21_BV7R11HS_CPIO.bin")
    parser.add_argument("--recovery-flags", default="")
    parser.add_argument("--main-flags", default="-gd")
    parser.add_argument("--webui-flags", default="-gd")
    parser.add_argument("--skip-datamode", action="store_true", default=False)
    parser.add_argument("--relax-datamode", action="store_true", default=True)
    parser.add_argument("--force-datamode", action="store_true", default=False)
    parser.add_argument("--state-file", default="/tmp/e3372h_needle_state.json")
    parser.add_argument("--wait-usbload", type=float, default=20.0)
    parser.add_argument("--wait-reboot", type=float, default=20.0)
    parser.add_argument(
        "--strategy",
        choices=("status", "anti-badblock", "shell-loader", "probe-1442", "shell-probe", "full-probe", "article-flow", "article-main", "article-webui", "article-reset"),
        default="full-probe",
    )
    parser.add_argument("--port", default="/dev/ttyUSB0")
    return parser


def main() -> int:
    args = build_parser().parse_args()

    if args.strategy == "status":
        log(f"pid={current_pid() or 'none'}")
        log(f"ttyUSB={ttyusb_ports()}")
        return 0

    if args.strategy == "anti-badblock":
        anti_badblock_stage(args)
        return 0

    if args.strategy == "shell-loader":
        shell_loader_stage(args)
        return 0

    if args.strategy == "probe-1442":
        print_probe(args.port)
        return 0

    if args.strategy == "shell-probe":
        print_shell_probe(args.port)
        return 0

    if args.strategy == "full-probe":
        pid, ports = anti_badblock_stage(args)
        if pid == "1442" and ports:
            print_probe(ports[0])
            return 0
        raise SystemExit(f"ERROR: expected clean 1442 after anti-badblock, got pid={pid} ports={ports}")

    if args.strategy == "article-flow":
        return article_flow(args)

    if args.strategy == "article-main":
        return article_main_flow(args)

    if args.strategy == "article-webui":
        return article_webui_flow(args)

    if args.strategy == "article-reset":
        return article_reset(args)

    raise SystemExit(f"ERROR: unsupported strategy: {args.strategy}")


if __name__ == "__main__":
    raise SystemExit(main())
