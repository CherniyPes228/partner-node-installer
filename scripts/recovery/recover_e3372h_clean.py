#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent.parent
FLASH_CLEAN = REPO_ROOT / "flash_clean"
INSTALLED_FLASH_ROOT = Path("/opt/partner-node-flash")
INSTALLED_STATE_ROOT = Path("/var/lib/partner-node/needle-recovery")


def log(message: str) -> None:
    print(message, flush=True)


def fail(message: str) -> int:
    log(f"ERROR: {message}")
    return 1


def first_existing(paths: list[Path]) -> Path | None:
    for path in paths:
        if path.exists():
            return path
    return None


def safe_text(value: object) -> str:
    text = str(value)
    return text.encode("ascii", "backslashreplace").decode("ascii")


def find_service_firmware() -> Path | None:
    direct = sorted((FLASH_CLEAN / "needle" / "main").rglob("P711s-STICK_UPDATE_21.110.99.04.00.BIN"))
    if direct:
        return direct[0]

    candidates = [
        FLASH_CLEAN / "needle" / "main" / "E3372h-153TCPU-21.110.99.04.00_Firmware+general" / "Software",
    ]
    for root in candidates:
        if not root.exists():
            continue
        matches = sorted(root.rglob("P711s-STICK_UPDATE_21.110.99.04.00.BIN"))
        if matches:
            return matches[0]
    installed_candidates = [
        INSTALLED_FLASH_ROOT / "images" / "E3372h-153_Update_21.329.62.00.209.bin",
        INSTALLED_FLASH_ROOT / "images" / "E3372h-153_Update_21.110.99.04.00.bin",
    ]
    installed = first_existing(installed_candidates)
    if installed is not None:
        return installed
    return None


def find_recovery_webui() -> Path | None:
    candidates = [
        FLASH_CLEAN / "needle" / "webui" / "Update_WEBUI_17.100.13.01.03_HILINK_Mod1.13.bin",
        FLASH_CLEAN
        / "needle"
        / "webui"
        / "Update_WEBUI_17.100.13.01.03_HILINK_Mod1.13"
        / "Update_WEBUI_17.100.13.01.03_HILINK_Mod1.13.bin",
        FLASH_CLEAN / "needle" / " webui" / "Update_WEBUI_17.100.13.01.03_HILINK_Mod1.13.bin",
        FLASH_CLEAN
        / "needle"
        / " webui"
        / "Update_WEBUI_17.100.13.01.03_HILINK_Mod1.13"
        / "Update_WEBUI_17.100.13.01.03_HILINK_Mod1.13.bin",
        FLASH_CLEAN / "needle" / "webui" / "Update_WEBUI_17.100.20.00.03_HILINK_ISO_only.bin",
        FLASH_CLEAN
        / "needle"
        / "webui"
        / "Update_WEBUI_17.100.20.00.03_HILINK_ISO_only"
        / "Update_WEBUI_17.100.20.00.03_HILINK_ISO_only.bin",
        FLASH_CLEAN
        / "needle"
        / " webui"
        / "Update_WEBUI_17.100.20.00.03_HILINK_ISO_only"
        / "Update_WEBUI_17.100.20.00.03_HILINK_ISO_only.bin",
        INSTALLED_FLASH_ROOT / "images" / "Update_WEBUI_17.100.13.01.03_HILINK_Mod1.13.bin",
        INSTALLED_FLASH_ROOT / "images" / "WEBUI_17.100.18.03.143_HILINK_Mod1.21_BV7R11HS_CPIO.bin",
    ]
    return first_existing(candidates)


def find_tool(path_parts: list[str]) -> Path | None:
    local = FLASH_CLEAN.joinpath(*path_parts)
    installed_tools = INSTALLED_FLASH_ROOT / "tools"
    installed = installed_tools / path_parts[-1]
    return first_existing([local, installed])


def default_state_file() -> Path:
    local_state = REPO_ROOT / "flash_clean" / "needle" / "state" / "recover_e3372h_clean.json"
    if local_state.parent.exists():
        return local_state
    return INSTALLED_STATE_ROOT / "recover_e3372h_clean.json"


def read_state(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {}
    except json.JSONDecodeError:
        return {}


def write_state(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")


def build_underlying_command(args: argparse.Namespace, strategy: str) -> list[str]:
    underlying = SCRIPT_DIR / "recover_e3372h_from_needle.py"
    if not underlying.exists():
        raise FileNotFoundError(f"missing underlying script: {underlying}")

    service_firmware = find_service_firmware()
    recovery_webui = find_recovery_webui()
    ptable = find_tool(["needle", "tools", "ptable-hilink.bin"])
    usblsafe = find_tool(["needle", "tools", "usblsafe-3372h.bin"])

    missing: list[str] = []
    if service_firmware is None:
        missing.append("service firmware 21.110.99.04.00")
    if recovery_webui is None:
        missing.append("needle recovery WebUI 17.100.20.00.03 ISO only")
    if ptable is None:
        missing.append("ptable-hilink.bin")
    if usblsafe is None:
        missing.append("usblsafe-3372h.bin")
    if missing:
        raise FileNotFoundError(", ".join(missing))

    state_file = args.state_file or default_state_file()
    state_file.parent.mkdir(parents=True, exist_ok=True)

    # Keep the clean wrapper authoritative for image selection.
    # Old state files may still point to experimental rescue assets such as
    # ISO-only WebUI images; override them here.
    state = read_state(state_file)
    state["main_image"] = str(service_firmware)
    state["webui_image"] = str(recovery_webui)
    write_state(state_file, state)

    command = [
        sys.executable,
        str(underlying),
        "--strategy",
        strategy,
        "--needle-port",
        args.needle_port,
        "--state-file",
        str(state_file),
        "--ptable",
        str(ptable),
        "--usblsafe",
        str(usblsafe),
        "--main-image",
        str(service_firmware),
        "--webui-image",
        str(recovery_webui),
    ]

    if args.port:
        command.extend(["--port", args.port])
    if args.balong_usbload:
        command.extend(["--balong-usbload", args.balong_usbload])
    if args.balong_flash:
        command.extend(["--balong-flash", args.balong_flash])
    if args.rawfbcmd:
        command.extend(["--rawfbcmd", args.rawfbcmd])

    return command


def describe_assets() -> int:
    log("Using clean needle recovery asset set:")
    log(f"- service firmware: {safe_text(find_service_firmware() or 'MISSING')}")
    log(f"- recovery webui:   {safe_text(find_recovery_webui() or 'MISSING')}")
    log(f"- ptable:           {safe_text(find_tool(['needle', 'tools', 'ptable-hilink.bin']) or 'MISSING')}")
    log(f"- usblsafe:         {safe_text(find_tool(['needle', 'tools', 'usblsafe-3372h.bin']) or 'MISSING')}")
    return 0


def run_phase(args: argparse.Namespace, phase: str) -> int:
    state_file = args.state_file or default_state_file()
    state = read_state(state_file)

    effective_phase = phase
    if phase == "article-flow" and state.get("phase") == "main_done":
        effective_phase = "article-webui"

    command = build_underlying_command(args, effective_phase)
    log("$ " + " ".join(command))
    completed = subprocess.run(command)
    return completed.returncode


def run_all(args: argparse.Namespace) -> int:
    state_file = args.state_file or default_state_file()
    state = read_state(state_file)
    phase = state.get("phase")

    if phase == "webui_done":
        log("Recovery already completed.")
        return 0

    if phase in {"main_done", "webui_pending"}:
        log("Continuing recovery from saved state: webui phase.")
        rc = run_phase(args, "article-flow")
        if rc == 0:
            log("Recovery completed.")
        return rc

    log("Starting recovery: reset + main phase.")
    rc = run_phase(args, "article-reset")
    if rc != 0:
        return rc

    rc = run_phase(args, "article-main")
    if rc != 0:
        return rc

    state = read_state(state_file)
    if state.get("phase") in {"main_done", "webui_pending"}:
        log("Main phase completed.")
        log("NEEDLE_REQUIRED: put the modem into needle mode again, then rerun the same command.")
        return 10

    log("Recovery did not reach saved main_done state.")
    return 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Clean standalone E3372h-153 needle recovery wrapper over the recovery engine.",
    )
    parser.add_argument(
        "phase",
        choices=("status", "assets", "reset", "main", "webui", "flow", "all"),
        help="Recovery phase to run.",
    )
    parser.add_argument("--needle-port", default="/dev/ttyUSB0")
    parser.add_argument("--port", default="/dev/ttyUSB0")
    parser.add_argument("--state-file", type=Path)
    parser.add_argument("--balong-usbload", default="/opt/partner-node-flash/tools/balong-usbload")
    parser.add_argument("--balong-flash", default="/opt/partner-node-flash/tools/balong_flash_recover")
    parser.add_argument("--rawfbcmd", default="/opt/partner-node-flash/tools/rawfbcmd")
    return parser


def main() -> int:
    args = build_parser().parse_args()

    if args.phase == "assets":
        return describe_assets()

    if args.phase == "status":
        try:
            return run_phase(args, "status")
        except FileNotFoundError as exc:
            return fail(str(exc))

    if args.phase == "reset":
        try:
            return run_phase(args, "article-reset")
        except FileNotFoundError as exc:
            return fail(str(exc))

    if args.phase == "main":
        try:
            return run_phase(args, "article-main")
        except FileNotFoundError as exc:
            return fail(str(exc))

    if args.phase == "webui":
        try:
            return run_phase(args, "article-webui")
        except FileNotFoundError as exc:
            return fail(str(exc))

    if args.phase == "flow":
        try:
            return run_phase(args, "article-flow")
        except FileNotFoundError as exc:
            return fail(str(exc))

    if args.phase == "all":
        try:
            return run_all(args)
        except FileNotFoundError as exc:
            return fail(str(exc))

    return fail(f"unsupported phase: {args.phase}")


if __name__ == "__main__":
    raise SystemExit(main())
