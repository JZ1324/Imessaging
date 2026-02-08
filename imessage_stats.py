#!/usr/bin/env python3
import argparse
import json
import sqlite3
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from statistics import mean, median
from typing import Dict, List, Optional, Tuple

APPLE_EPOCH = datetime(2001, 1, 1, tzinfo=timezone.utc)


@dataclass
class Message:
    message_id: int
    chat_id: int
    chat_identifier: str
    display_name: Optional[str]
    handle: Optional[str]
    date_raw: Optional[int]
    date_read_raw: Optional[int]
    is_from_me: int


def detect_date_scale(max_date_value: Optional[int]) -> Tuple[int, str]:
    if not max_date_value:
        return 1, "seconds"
    # Heuristic based on magnitude
    if max_date_value > 1e17:
        return 1_000_000_000, "nanoseconds"
    if max_date_value > 1e14:
        return 1_000_000, "microseconds"
    if max_date_value > 1e11:
        return 1_000, "milliseconds"
    return 1, "seconds"


def apple_time_to_datetime(value: Optional[int], divisor: int) -> Optional[datetime]:
    if value is None:
        return None
    try:
        seconds = value / divisor
    except Exception:
        return None
    return APPLE_EPOCH + timedelta(seconds=seconds)


def datetime_to_apple(value: datetime, divisor: int) -> int:
    delta = value.astimezone(timezone.utc) - APPLE_EPOCH
    return int(delta.total_seconds() * divisor)


def load_messages(conn: sqlite3.Connection, since_raw: Optional[int], until_raw: Optional[int]) -> List[Message]:
    where = []
    params: List[int] = []
    if since_raw is not None:
        where.append("m.date >= ?")
        params.append(since_raw)
    if until_raw is not None:
        where.append("m.date <= ?")
        params.append(until_raw)
    where_clause = " AND ".join(where)
    if where_clause:
        where_clause = "WHERE " + where_clause

    sql = f"""
        SELECT
            m.ROWID as message_id,
            m.date as date_raw,
            m.date_read as date_read_raw,
            m.is_from_me as is_from_me,
            m.handle_id as handle_id,
            c.ROWID as chat_id,
            c.chat_identifier as chat_identifier,
            c.display_name as display_name,
            h.id as handle
        FROM message m
        JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
        JOIN chat c ON c.ROWID = cmj.chat_id
        LEFT JOIN handle h ON m.handle_id = h.ROWID
        {where_clause}
        ORDER BY c.ROWID ASC, m.date ASC
    """
    cur = conn.execute(sql, params)
    rows = cur.fetchall()

    messages: List[Message] = []
    for row in rows:
        messages.append(
            Message(
                message_id=row[0],
                date_raw=row[1],
                date_read_raw=row[2],
                is_from_me=row[3],
                chat_id=row[5],
                chat_identifier=row[6],
                display_name=row[7],
                handle=row[8],
            )
        )
    return messages


def next_opposite_times(messages: List[Message], divisor: int) -> Tuple[List[Optional[int]], List[Optional[int]]]:
    next_from_me_raw: Optional[int] = None
    next_from_them_raw: Optional[int] = None
    next_reply_time_raw: List[Optional[int]] = [None] * len(messages)
    next_reply_type: List[Optional[int]] = [None] * len(messages)  # 1 if from me, 0 if from them

    for i in range(len(messages) - 1, -1, -1):
        msg = messages[i]
        if msg.is_from_me == 1:
            next_reply_time_raw[i] = next_from_them_raw
            next_reply_type[i] = 0 if next_from_them_raw is not None else None
            if msg.date_raw is not None:
                next_from_me_raw = msg.date_raw
        else:
            next_reply_time_raw[i] = next_from_me_raw
            next_reply_type[i] = 1 if next_from_me_raw is not None else None
            if msg.date_raw is not None:
                next_from_them_raw = msg.date_raw
    return next_reply_time_raw, next_reply_type


def summarize_response_times(durations_minutes: List[float]) -> Dict[str, Optional[float]]:
    if not durations_minutes:
        return {
            "count": 0,
            "avg_minutes": None,
            "median_minutes": None,
            "p90_minutes": None,
        }
    sorted_vals = sorted(durations_minutes)
    p90_index = max(0, int(round(0.9 * (len(sorted_vals) - 1))))
    return {
        "count": len(sorted_vals),
        "avg_minutes": round(mean(sorted_vals), 2),
        "median_minutes": round(median(sorted_vals), 2),
        "p90_minutes": round(sorted_vals[p90_index], 2),
    }


def build_report(messages: List[Message], divisor: int, threshold_hours: float, top: int) -> Dict:
    threshold_seconds = threshold_hours * 3600

    chats: Dict[int, Dict] = {}

    # Organize by chat
    messages_by_chat: Dict[int, List[Message]] = {}
    for msg in messages:
        messages_by_chat.setdefault(msg.chat_id, []).append(msg)

    totals_sent = 0
    totals_received = 0
    left_on_read_you = 0
    left_on_read_them = 0
    you_reply_minutes: List[float] = []
    them_reply_minutes: List[float] = []

    for chat_id, msgs in messages_by_chat.items():
        label = None
        display_name = msgs[0].display_name if msgs else None
        if display_name:
            label = display_name
        else:
            label = msgs[0].chat_identifier if msgs else str(chat_id)

        sent = 0
        received = 0
        you_left = 0
        them_left = 0
        you_reply: List[float] = []
        them_reply: List[float] = []

        next_times_raw, _ = next_opposite_times(msgs, divisor)

        for idx, msg in enumerate(msgs):
            if msg.is_from_me == 1:
                sent += 1
            else:
                received += 1

            # response times
            next_raw = next_times_raw[idx]
            if next_raw is not None and msg.date_raw is not None:
                dt_seconds = (next_raw - msg.date_raw) / divisor
                if dt_seconds >= 0:
                    minutes = dt_seconds / 60
                    if msg.is_from_me == 1:
                        them_reply.append(minutes)
                    else:
                        you_reply.append(minutes)

            # left on read checks
            date_read_raw = msg.date_read_raw if msg.date_read_raw not in (None, 0) else None
            if date_read_raw is not None and msg.date_raw is not None:
                base_raw = date_read_raw
                next_raw = next_times_raw[idx]
                replied_in_time = False
                if next_raw is not None and base_raw is not None:
                    dt_seconds = (next_raw - base_raw) / divisor
                    if dt_seconds >= 0 and dt_seconds <= threshold_seconds:
                        replied_in_time = True
                if msg.is_from_me == 1:
                    if not replied_in_time:
                        them_left += 1
                else:
                    if not replied_in_time:
                        you_left += 1

        totals_sent += sent
        totals_received += received
        left_on_read_you += you_left
        left_on_read_them += them_left
        you_reply_minutes.extend(you_reply)
        them_reply_minutes.extend(them_reply)

        chats[chat_id] = {
            "chat_id": chat_id,
            "chat_identifier": msgs[0].chat_identifier if msgs else str(chat_id),
            "display_name": display_name,
            "label": label,
            "totals": {
                "sent": sent,
                "received": received,
                "total": sent + received,
            },
            "left_on_read": {
                "you_left_them": you_left,
                "they_left_you": them_left,
            },
            "response_times": {
                "you_reply": summarize_response_times(you_reply),
                "they_reply": summarize_response_times(them_reply),
            },
        }

    # Sort chats by total messages
    chat_list = list(chats.values())
    chat_list.sort(key=lambda c: c["totals"]["total"], reverse=True)

    summary = {
        "totals": {
            "sent": totals_sent,
            "received": totals_received,
            "total": totals_sent + totals_received,
        },
        "left_on_read": {
            "you_left_them": left_on_read_you,
            "they_left_you": left_on_read_them,
        },
        "response_times": {
            "you_reply": summarize_response_times(you_reply_minutes),
            "they_reply": summarize_response_times(them_reply_minutes),
        },
    }

    return {
        "summary": summary,
        "chats": chat_list[:top],
    }


def render_html(report: Dict, output_path: str) -> None:
    summary = report["summary"]
    chats = report["chats"]

    def fmt(val):
        return "—" if val is None else str(val)

    html = f"""<!doctype html>
<html lang=\"en\">
<head>
<meta charset=\"utf-8\" />
<title>iMessage Stats</title>
<style>
body {{ font-family: -apple-system, BlinkMacSystemFont, Segoe UI, Roboto, Helvetica, Arial, sans-serif; margin: 32px; color: #111; }}
header {{ margin-bottom: 24px; }}
section {{ margin-top: 24px; }}
.card {{ border: 1px solid #e5e5e5; border-radius: 12px; padding: 16px; margin-bottom: 16px; }}
.grid {{ display: grid; grid-template-columns: repeat(3, 1fr); gap: 12px; }}
small {{ color: #666; }}
</style>
</head>
<body>
<header>
  <h1>iMessage Stats (No-AI)</h1>
  <small>Generated locally</small>
</header>
<section class=\"card\">
  <h2>Summary</h2>
  <div class=\"grid\">
    <div><strong>Sent</strong><br>{summary['totals']['sent']}</div>
    <div><strong>Received</strong><br>{summary['totals']['received']}</div>
    <div><strong>Total</strong><br>{summary['totals']['total']}</div>
    <div><strong>You left them on read</strong><br>{summary['left_on_read']['you_left_them']}</div>
    <div><strong>They left you on read</strong><br>{summary['left_on_read']['they_left_you']}</div>
  </div>
</section>
<section class=\"card\">
  <h2>Response Times (minutes)</h2>
  <div class=\"grid\">
    <div><strong>Your replies</strong><br>Avg {fmt(summary['response_times']['you_reply']['avg_minutes'])}, Median {fmt(summary['response_times']['you_reply']['median_minutes'])}, P90 {fmt(summary['response_times']['you_reply']['p90_minutes'])}</div>
    <div><strong>Their replies</strong><br>Avg {fmt(summary['response_times']['they_reply']['avg_minutes'])}, Median {fmt(summary['response_times']['they_reply']['median_minutes'])}, P90 {fmt(summary['response_times']['they_reply']['p90_minutes'])}</div>
  </div>
</section>
<section>
  <h2>Top Chats</h2>
  {''.join([f"""
  <div class=\"card\">
    <h3>{c['label']}</h3>
    <div class=\"grid\">
      <div><strong>Sent</strong><br>{c['totals']['sent']}</div>
      <div><strong>Received</strong><br>{c['totals']['received']}</div>
      <div><strong>Total</strong><br>{c['totals']['total']}</div>
      <div><strong>You left them on read</strong><br>{c['left_on_read']['you_left_them']}</div>
      <div><strong>They left you on read</strong><br>{c['left_on_read']['they_left_you']}</div>
    </div>
    <p><small>Your replies: Avg {fmt(c['response_times']['you_reply']['avg_minutes'])}, Median {fmt(c['response_times']['you_reply']['median_minutes'])}, P90 {fmt(c['response_times']['you_reply']['p90_minutes'])}</small></p>
    <p><small>Their replies: Avg {fmt(c['response_times']['they_reply']['avg_minutes'])}, Median {fmt(c['response_times']['they_reply']['median_minutes'])}, P90 {fmt(c['response_times']['they_reply']['p90_minutes'])}</small></p>
  </div>
  """ for c in chats])}
</section>
</body>
</html>"""

    with open(output_path, "w", encoding="utf-8") as f:
        f.write(html)


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate iMessage stats (no AI).")
    parser.add_argument("--db", required=True, help="Path to chat.db copy")
    parser.add_argument("--output-html", required=True, help="Path to write HTML report")
    parser.add_argument("--output-json", required=True, help="Path to write JSON report")
    parser.add_argument("--since", help="Start date YYYY-MM-DD (local time)")
    parser.add_argument("--until", help="End date YYYY-MM-DD (local time)")
    parser.add_argument("--threshold-hours", type=float, default=24, help="Hours before counting as left on read")
    parser.add_argument("--top", type=int, default=20, help="Top chats to include")

    args = parser.parse_args()

    conn = sqlite3.connect(args.db)
    conn.row_factory = sqlite3.Row

    max_date = conn.execute("SELECT MAX(date) FROM message").fetchone()[0]
    divisor, scale_label = detect_date_scale(max_date)

    since_raw = None
    until_raw = None
    if args.since:
        local_tz = datetime.now().astimezone().tzinfo
        since_dt = datetime.fromisoformat(args.since).replace(tzinfo=local_tz)
        since_raw = datetime_to_apple(since_dt, divisor)
    if args.until:
        local_tz = datetime.now().astimezone().tzinfo
        until_dt = datetime.fromisoformat(args.until).replace(tzinfo=local_tz) + timedelta(days=1)
        until_raw = datetime_to_apple(until_dt, divisor)

    messages = load_messages(conn, since_raw, until_raw)
    report = build_report(messages, divisor, args.threshold_hours, args.top)

    report["generated_at"] = datetime.now(timezone.utc).astimezone().isoformat()
    report["filters"] = {
        "since": args.since,
        "until": args.until,
        "threshold_hours": args.threshold_hours,
        "top": args.top,
        "date_scale": scale_label,
    }

    with open(args.output_json, "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2)

    render_html(report, args.output_html)

    print(f"Wrote {args.output_html} and {args.output_json}")


if __name__ == "__main__":
    main()
