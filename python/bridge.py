#!/usr/bin/env python3
"""bridge.py - Jupyter kernel bridge via stdin/stdout JSON Lines.

Protocol:
  Input  (stdin):  one JSON object per line, fields: id, method, params
  Output (stdout): one JSON object per line, fields: id, stream/ok/error, output/result

Supported methods:
  kernel_start    - Start a Jupyter kernel
  execute         - Execute code, stream outputs
  kernel_interrupt - Interrupt running execution
  kernel_restart  - Restart the kernel
  kernel_shutdown - Shutdown the kernel
  is_alive        - Check if the kernel is alive
"""

import json
import sys
import threading
from typing import Any

from jupyter_client import KernelManager

# ---------------------------------------------------------------------------
# Global state
# ---------------------------------------------------------------------------

_km: KernelManager | None = None
_kc = None  # KernelClient
_iopub_thread: threading.Thread | None = None
_iopub_stop = threading.Event()

# Map from kernel msg_id -> request_id (for routing iopub messages)
_pending: dict[str, str] = {}
_pending_lock = threading.Lock()

# Map from request_id -> execute_result info (written by iopub, read after shell reply)
_execute_results: dict[str, dict[str, Any]] = {}

_stdout_lock = threading.Lock()


# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------


def _emit(obj: dict[str, Any]) -> None:
    """Write a JSON line to stdout, thread-safe."""
    line = json.dumps(obj, ensure_ascii=False)
    with _stdout_lock:
        sys.stdout.write(line + "\n")
        sys.stdout.flush()


def _emit_stream(request_id: str, output: dict[str, Any]) -> None:
    _emit({"id": request_id, "stream": True, "output": output})


def _emit_ok(request_id: str, result: dict[str, Any]) -> None:
    _emit({"id": request_id, "ok": True, "result": result})


def _emit_error(request_id: str, message: str) -> None:
    _emit({"id": request_id, "ok": False, "error": message})


# ---------------------------------------------------------------------------
# IOPub monitor thread
# ---------------------------------------------------------------------------


def _iopub_monitor() -> None:
    """Background thread: read IOPub messages and route to pending requests."""
    global _kc
    while not _iopub_stop.is_set():
        if _kc is None:
            _iopub_stop.wait(timeout=0.1)
            continue
        try:
            msg = _kc.get_iopub_msg(timeout=0.5)
        except Exception:
            # Timeout or kernel gone — keep looping
            continue

        msg_type = msg.get("msg_type", "")
        parent_id = msg.get("parent_header", {}).get("msg_id", "")
        content = msg.get("content", {})

        with _pending_lock:
            request_id = _pending.get(parent_id)

        if request_id is None:
            continue

        if msg_type == "status":
            state = content.get("execution_state", "")
            _emit_stream(request_id, {"type": "status", "state": state})

        elif msg_type == "stream":
            _emit_stream(request_id, {
                "type": "stream",
                "name": content.get("name", "stdout"),
                "text": content.get("text", ""),
            })

        elif msg_type == "execute_result":
            output = {
                "type": "execute_result",
                "data": content.get("data", {}),
                "execution_count": content.get("execution_count"),
            }
            _emit_stream(request_id, output)
            with _pending_lock:
                _execute_results[request_id] = {
                    "execution_count": content.get("execution_count"),
                }

        elif msg_type == "display_data":
            _emit_stream(request_id, {
                "type": "display_data",
                "data": content.get("data", {}),
                "metadata": content.get("metadata", {}),
            })

        elif msg_type == "error":
            _emit_stream(request_id, {
                "type": "error",
                "ename": content.get("ename", ""),
                "evalue": content.get("evalue", ""),
                "traceback": content.get("traceback", []),
            })


# ---------------------------------------------------------------------------
# Method handlers
# ---------------------------------------------------------------------------


def _start_iopub_thread() -> None:
    global _iopub_thread, _iopub_stop
    _iopub_stop.clear()
    _iopub_thread = threading.Thread(target=_iopub_monitor, daemon=True)
    _iopub_thread.start()


def handle_kernel_start(request_id: str, params: dict[str, Any]) -> None:
    global _km, _kc

    kernel_name = params.get("kernel_name", "python3")
    cwd = params.get("cwd") or None

    try:
        if _kc is not None:
            try:
                _kc.stop_channels()
            except Exception:
                pass
        if _km is not None:
            try:
                _km.shutdown_kernel(now=True)
            except Exception:
                pass

        _km = KernelManager(kernel_name=kernel_name)
        if cwd:
            _km.cwd = cwd
        _km.start_kernel()
        _kc = _km.client()
        _kc.start_channels()
        _kc.wait_for_ready(timeout=30)

        _start_iopub_thread()

        _emit_ok(request_id, {"status": "started", "kernel_name": kernel_name})
    except Exception as exc:
        _emit_error(request_id, f"kernel_start failed: {exc}")


def handle_execute(request_id: str, params: dict[str, Any]) -> None:
    global _kc

    if _kc is None:
        _emit_error(request_id, "No kernel running. Call kernel_start first.")
        return

    code = params.get("code", "")

    try:
        msg_id = _kc.execute(code)
    except Exception as exc:
        _emit_error(request_id, f"execute failed: {exc}")
        return

    with _pending_lock:
        _pending[msg_id] = request_id

    # Wait for execute_reply on the shell channel.
    # Use a finite timeout so kernel_interrupt and kernel_shutdown can still
    # be processed if the kernel hangs.
    try:
        while True:
            try:
                reply = _kc.get_shell_msg(timeout=30)
            except Exception:
                # Timeout — check if the kernel is still alive.
                if _km is None or not _km.is_alive():
                    with _pending_lock:
                        _pending.pop(msg_id, None)
                    _emit_error(request_id, "Kernel died during execution")
                    return
                # Kernel is alive but slow — keep waiting.
                continue
            if reply.get("parent_header", {}).get("msg_id") == msg_id:
                break
    except Exception as exc:
        with _pending_lock:
            _pending.pop(msg_id, None)
        _emit_error(request_id, f"execute reply failed: {exc}")
        return

    with _pending_lock:
        _pending.pop(msg_id, None)
        exec_count_info = _execute_results.pop(request_id, {})

    content = reply.get("content", {})
    status = content.get("status", "error")
    execution_count = content.get("execution_count") or exec_count_info.get("execution_count")

    if status == "ok":
        _emit_ok(request_id, {
            "execution_count": execution_count,
            "status": "ok",
        })
    else:
        _emit_ok(request_id, {
            "execution_count": execution_count,
            "status": status,
            "ename": content.get("ename", ""),
            "evalue": content.get("evalue", ""),
        })


def handle_kernel_interrupt(request_id: str, _params: dict[str, Any]) -> None:
    global _km
    if _km is None:
        _emit_error(request_id, "No kernel running.")
        return
    try:
        _km.interrupt_kernel()
        _emit_ok(request_id, {"status": "interrupted"})
    except Exception as exc:
        _emit_error(request_id, f"interrupt failed: {exc}")


def handle_kernel_restart(request_id: str, _params: dict[str, Any]) -> None:
    global _km, _kc
    if _km is None:
        _emit_error(request_id, "No kernel running.")
        return
    try:
        _km.restart_kernel(now=True)
        _kc = _km.client()
        _kc.start_channels()
        _kc.wait_for_ready(timeout=30)

        with _pending_lock:
            _pending.clear()
            _execute_results.clear()

        _emit_ok(request_id, {"status": "restarted"})
    except Exception as exc:
        _emit_error(request_id, f"restart failed: {exc}")


def handle_kernel_shutdown(request_id: str, _params: dict[str, Any]) -> None:
    global _km, _kc
    _iopub_stop.set()
    try:
        if _kc is not None:
            _kc.stop_channels()
            _kc = None
        if _km is not None:
            _km.shutdown_kernel(now=True)
            _km = None
        _emit_ok(request_id, {"status": "shutdown"})
    except Exception as exc:
        _emit_error(request_id, f"shutdown failed: {exc}")


def handle_is_alive(request_id: str, _params: dict[str, Any]) -> None:
    global _km
    alive = _km is not None and _km.is_alive()
    _emit_ok(request_id, {"alive": alive})


# ---------------------------------------------------------------------------
# Dispatch table
# ---------------------------------------------------------------------------

_HANDLERS = {
    "kernel_start": handle_kernel_start,
    "execute": handle_execute,
    "kernel_interrupt": handle_kernel_interrupt,
    "kernel_restart": handle_kernel_restart,
    "kernel_shutdown": handle_kernel_shutdown,
    "is_alive": handle_is_alive,
}


# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------


def _safe_call(handler, request_id: str, params: dict[str, Any]) -> None:
    """Call a handler, catching and reporting any unhandled exception."""
    try:
        handler(request_id, params)
    except Exception as exc:
        _emit_error(request_id, f"Unhandled exception: {exc}")


def main() -> None:
    """Read JSON lines from stdin and dispatch to handlers."""
    for raw_line in sys.stdin:
        line = raw_line.strip()
        if not line:
            continue

        try:
            request = json.loads(line)
        except json.JSONDecodeError as exc:
            # Cannot echo a proper id; write a generic error
            _emit({"id": None, "ok": False, "error": f"JSON decode error: {exc}"})
            continue

        request_id = request.get("id")
        method = request.get("method", "")
        params = request.get("params") or {}

        handler = _HANDLERS.get(method)
        if handler is None:
            _emit_error(request_id, f"Unknown method: {method!r}")
            continue

        # execute blocks on get_shell_msg; run it in a background thread
        # so the main loop can still process interrupt/shutdown requests.
        if method == "execute":
            t = threading.Thread(
                target=_safe_call, args=(handler, request_id, params), daemon=True
            )
            t.start()
        else:
            _safe_call(handler, request_id, params)

    # stdin closed (EOF) — graceful shutdown
    _iopub_stop.set()
    if _kc is not None:
        try:
            _kc.stop_channels()
        except Exception:
            pass
    if _km is not None:
        try:
            _km.shutdown_kernel(now=True)
        except Exception:
            pass


if __name__ == "__main__":
    main()
