#!/usr/bin/env python3
"""Render short 5xx windows from a VictoriaMetrics query_range response."""

from __future__ import annotations

import datetime as dt
import json
import math
import sys


def short_windows(payload: dict, *, step_seconds: int = 60, page_after_seconds: int = 120):
    if payload.get("status") != "success":
        raise ValueError("VictoriaMetrics returned a non-success response")
    data = payload.get("data") or {}
    if data.get("resultType") != "matrix":
        raise ValueError("VictoriaMetrics response is not a range matrix")

    found = []
    for series in data.get("result") or []:
        labels = series.get("metric") or {}
        host = labels.get("host") or labels.get("instance") or "unknown-host"
        router = labels.get("router") or "unknown-router"
        points = []
        for timestamp, raw_value in series.get("values") or []:
            try:
                value = float(raw_value)
                timestamp = int(float(timestamp))
            except (TypeError, ValueError):
                continue
            if math.isfinite(value) and value > 0:
                points.append((timestamp, value))

        groups = []
        for timestamp, value in points:
            if not groups or timestamp - groups[-1][-1][0] > step_seconds * 1.5:
                groups.append([])
            groups[-1].append((timestamp, value))

        for group in groups:
            duration = group[-1][0] - group[0][0] + step_seconds
            if duration >= page_after_seconds:
                continue
            found.append(
                {
                    "host": host,
                    "router": router,
                    "start": group[0][0],
                    "end": group[-1][0] + step_seconds,
                    "duration": duration,
                    "count": sum(value for _, value in group),
                }
            )
    return sorted(found, key=lambda item: (item["start"], item["host"], item["router"]))


def _utc(timestamp: int) -> str:
    return dt.datetime.fromtimestamp(timestamp, tz=dt.timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")


def render(payload: dict, *, start: int, end: int) -> str:
    windows = short_windows(payload)
    lines = [
        "Short Traefik 502/503/504 windows from VictoriaMetrics:",
        f"Window: {_utc(start)} through {_utc(end)}",
    ]
    if not windows:
        lines.append("No short 5xx windows were recorded.")
    else:
        lines.append(f"{len(windows)} short window(s):")
        for window in windows:
            lines.append(
                "- {host} {router}: {start} to {end} ({duration}s, ~{count:.0f} responses)".format(
                    host=window["host"],
                    router=window["router"],
                    start=_utc(window["start"]),
                    end=_utc(window["end"]),
                    duration=window["duration"],
                    count=window["count"],
                )
            )
    return "\n".join(lines)


def main() -> int:
    try:
        start, end = int(sys.argv[1]), int(sys.argv[2])
        payload = json.load(sys.stdin)
        print(render(payload, start=start, end=end))
    except (IndexError, ValueError, json.JSONDecodeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
