# MonsterFX Reliable Trader v5.0

A complete automated trading system that connects **MetaTrader 5** to a **Discord community server** via a Python webhook bot.

## How It Works

```
MT5 (EA running on chart)
        │
        │  HTTP POST (JSON)
        ▼
Python Bot (Flask webhook server)
        │
        │  Discord API
        ▼
Discord Server (channels: open trades, closed trades, gold signals, daily report)
```

- The **MT5 Expert Advisor** detects trade signals, opens/closes positions, and sends updates to the Python bot over HTTP.
- The **Python bot** receives those updates and posts them as rich embeds to the correct Discord channels.
- **Gold (XAUUSD)** signals are sent to a VIP-only channel for manual execution — Gold is never auto-traded.
- A **daily report** is posted at 21:00 UTC summarising all Gold signal performance.

## Strategy

- **Pairs:** EURUSD, USDCAD, EURGBP (auto-traded) + XAUUSD (signals only)
- **Timeframes:** M15 trend filter + M5 entry
- **Indicators:** EMA 21/50 crossover, EMA 200 trend filter, RSI 14, VWAP, ATR-based SL/TP
- **Session filter:** London (08:00–16:00 GMT) + New York (13:00–21:00 GMT)
- **Risk limits:** Max 2 concurrent trades, max 7 trades/day, 20% max drawdown, 10% max daily loss

## Setup

### 1. Python Bot

**Install dependencies:**
```bash
pip install -r requirements.txt
```

**Configure environment:**
```bash
cp _env.example _env
```

Edit `_env` and fill in:

| Variable | Description |
|---|---|
| `DISCORD_BOT_TOKEN` | Your bot token from Discord Developer Portal |
| `WEBHOOK_SECRET` | Must match `SecretKey` in the MT5 EA settings |
| `WEBHOOK_PORT` | Port the Flask server listens on (default: 5000) |
| `TRADE_ALERTS_CHANNEL` | Channel ID for closed trade alerts |
| `GOLD_SIGNALS_CHANNEL` | Channel ID for Gold VIP signals |
| `BOT_LOGS_CHANNEL` | Channel ID for bot logs |
| `SUBSCRIBER_ROLE` | Role ID for paid subscribers |
| `GOLD_VIP_ROLE` | Role ID for Gold VIP (server boosters) |

**Run the bot:**
```bash
python3 bot_production.py
```

### 2. MT5 Expert Advisor

1. Copy `MonsterFX_AutoTrader.mq5` into your MT5 `MQL5/Experts/` folder.
2. Compile it in MetaEditor (F7).
3. In MT5: **Tools → Options → Expert Advisors**
   - Check **"Allow WebRequest for listed URL"**
   - Add `http://127.0.0.1:5000`
4. Attach the EA to a chart and set:
   - `ServerURL` = `http://127.0.0.1:5000`
   - `SecretKey` = same value as `WEBHOOK_SECRET` in your `_env` file

> **Important:** Start the Python bot **before** attaching the EA in MT5, so the webhook server is ready when the EA sends its first startup message.

## Discord Commands

| Command | Permission | Description |
|---|---|---|
| `/status` | Everyone | Show live account balance, equity, drawdown |
| `/trades` | Everyone | List all currently open positions |
| `/gold` | Admin | Manually send a Gold signal to the VIP channel |
| `/goldtp` | Admin | Manually record a Gold TP/SL result |
| `/goldreport` | Admin | Send the Gold daily report immediately |
| `/addsub` | Admin | Grant subscriber role to a user |
| `/removesub` | Admin | Remove subscriber role from a user |

## Channel Structure (Recommended)

```
Discord Server
├── #open-trades       ← Live open positions (auto-updated, auto-deleted on close)
├── #trade-alerts      ← Closed trades + system messages
├── #gold-signals      ← Gold VIP signals (visible to Gold VIP role only)
└── #gold-report       ← Daily Gold performance report
```

## Security Notes

- Never commit your `_env` file — it is listed in `.gitignore`.
- If your Discord bot token is ever shared publicly, regenerate it immediately in the [Discord Developer Portal](https://discord.com/developers/applications).
- The `WEBHOOK_SECRET` / `SecretKey` prevents unauthorised requests to the Flask server.

## Files

| File | Description |
|---|---|
| `bot_production.py` | Main Python bot (Discord + Flask webhook server) |
| `MonsterFX_AutoTrader.mq5` | MT5 Expert Advisor source code |
| `requirements.txt` | Python dependencies |
| `_env.example` | Environment variable template |
| `_env` | Your local secrets — **do not commit** |
