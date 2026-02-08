# iMessage Stats (No-AI)

Product page for iMessages Stats lives in `Imessaging/`.

Local iMessage stats from your `chat.db`, without any AI analysis. The script generates:
- totals (sent/received)
- response time stats
- left-on-read counts (you vs. them)
- per-chat breakdown
- a standalone HTML report

## 1) Export a copy of your database
Close the Messages app first so the database isn't locked.

```bash
mkdir -p data out
cp ~/Library/Messages/chat.db data/chat.db
```

If that copy fails, you may need to grant your terminal **Full Disk Access** in System Settings.

## 2) Generate the report

```bash
python imessage_stats.py --db data/chat.db --output-html out/report.html --output-json out/report.json
```

Optional flags:
- `--since YYYY-MM-DD`
- `--until YYYY-MM-DD`
- `--threshold-hours 24`
- `--top 20`

## 3) Open the report
Open `out/report.html` in your browser.

---

If you want a native macOS app UI (SwiftUI or Electron), we can layer that on next.

---

## macOS App (SwiftUI)

There is a SwiftUI macOS app in `ImessageStatsMacApp/` that generates the same report.

### Run with SwiftPM
```bash
cd ImessageStatsMacApp
swift run
```

### Run with Xcode
```bash
cd ImessageStatsMacApp
open Package.swift
```

### Notes
- Use a **copy** of `chat.db` (close Messages first) to avoid locks.
- If you point the app at the original database, grant **Full Disk Access** to the app in System Settings.
