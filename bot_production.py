import discord
from discord.ext import commands, tasks
from discord import app_commands
import asyncio
from flask import Flask, request, jsonify
import threading
from datetime import datetime, time, timedelta
import os
import json
import re
from dotenv import load_dotenv

# Thread-safe lock for the trade updates queue
_queue_lock = threading.Lock()

load_dotenv()

                                             
BOT_TOKEN = os.getenv("DISCORD_BOT_TOKEN")
SECRET_KEY = os.getenv("WEBHOOK_SECRET", "monster_fx_secret_2024")
WEBHOOK_PORT = int(os.getenv("WEBHOOK_PORT", 5000))

             
OPEN_TRADES_CHANNEL = 1448205653347794965                                               
CLOSED_TRADES_CHANNEL = int(os.getenv("TRADE_ALERTS_CHANNEL", 0))                      
GOLD_SIGNALS_CHANNEL = int(os.getenv("GOLD_SIGNALS_CHANNEL", 0))                     
GOLD_REPORT_CHANNEL = 1448206753929105500                          
BOT_LOGS_CHANNEL = int(os.getenv("BOT_LOGS_CHANNEL", 0))

          
SUBSCRIBER_ROLE = int(os.getenv("SUBSCRIBER_ROLE", 0))
GOLD_VIP_ROLE = int(os.getenv("GOLD_VIP_ROLE", 0))

               
TRADING_PAIRS = ["EURUSD", "USDCAD", "EURGBP"]
GOLD_PAIR = "XAUUSD"

                                  
MIN_TP_PIPS_REGULAR = 15                           
MIN_TP_PIPS_GOLD = 300

MAX_FOREX_TRADES_PER_DAY = 7
MIN_FOREX_TRADES_PER_DAY = 5
MAX_CONCURRENT_TRADES = 2
MAX_DRAWDOWN_PERCENT = 20.0
MAX_GOLD_SIGNALS_PER_DAY = 5
MAX_DAILY_LOSS_PERCENT = 10.0

                                            
account_status = {
    "balance": 0,
    "equity": 0,
    "margin": 0,
    "free_margin": 0,
    "drawdown": 0,
    "open_trades": 0,
    "trading_enabled": True,
    "last_update": None
}

open_trades = []
trade_updates_queue = []

                                        
open_trade_messages = {}                        

daily_trading_stats = {
    "date": datetime.now().date(),
    "forex_trades_count": 0,
    "daily_profit_loss": 0.0,
    "starting_balance": 0.0
}

                                       
gold_signals_today = {
    "signals": [],
    "total_pips": 0,
    "total_profit": 0,
    "tp1_hit": 0,
    "tp2_hit": 0,
    "tp3_hit": 0,
    "sl_hit": 0,
    "date": datetime.now().date()
}

                                                 
intents = discord.Intents.default()
intents.message_content = True
intents.members = True
intents.guilds = True

bot = commands.Bot(command_prefix="!", intents=intents)


                                            
def add_emojis_to_message(message, action):
                                                             
    if not message:
        return message
    
    replacements = {
        "[OK]": "✓",
        "\\n": "\n",
        "RELIABLE BUY Signal": "🟢 RELIABLE BUY Signal",
        "RELIABLE SELL Signal": "🔴 RELIABLE SELL Signal",
        "Position Closed": "🔄 Position Closed",
        "All Positions Closed": "🛑 All Positions Closed",
        "MAX DRAWDOWN REACHED": "⚠️ MAX DRAWDOWN REACHED",
        "Drawdown Warning": "⚠️ Drawdown Warning",
        "MonsterFX RELIABLE Trader Started": "🚀 MonsterFX RELIABLE Trader Started",
        "MonsterFX Reliable Trader Stopped": "🛑 MonsterFX Reliable Trader Stopped",
        "Strategy:": "📊 Strategy:",
        "Trend Filter:": "📈 Trend Filter:",
        "RSI Filter:": "📉 RSI Filter:",
        "Timeframe:": "⏱️ Timeframe:",
        "Session Filter:": "🕐 Session Filter:",
        "Lot Size:": "📦 Lot Size:",
        "Max DD:": "🛑 Max DD:",
        "Trailing Stop:": "🎯 Trailing Stop:",
        "Pairs:": "💹 Pairs:",
        "Type:": "📊 Type:",
        "Open:": "📈 Open:",
        "Close:": "📉 Close:",
        "Profit:": "💰 Profit:",
        "Reason:": "📝 Reason:",
        "Closed:": "✅ Closed:",
        "Total P/L:": "💵 Total P/L:",
        "Initial:": "💰 Initial:",
        "Equity:": "📊 Equity:",
    }
    
    result = message
    for old, new in replacements.items():
        result = result.replace(old, new)
    
    return result


                                              
def create_open_trade_embed(data):
                                              
    action = data.get("action", "UNKNOWN")
    symbol = data.get("symbol", "N/A")
    price = data.get("price", 0)
    sl = data.get("sl", 0)
    tp = data.get("tp", 0)
    lot = data.get("lot", 0.01)
    ticket = data.get("ticket", 0)
    balance = data.get("balance", 0)
    equity = data.get("equity", 0)
    message = data.get("message", "")
    
    color = 0x00FF00 if action == "BUY" else 0xFF0000
    
    embed = discord.Embed(
        title="📊 FOREX AUTO TRADE",
        color=color,
        timestamp=datetime.utcnow()
    )
    
    embed.add_field(name="Pair", value=f"`{symbol}`", inline=False)
    embed.add_field(name="Type", value=f"`{action}`", inline=True)
    embed.add_field(name="Entry", value=f"`{price:.5f}`", inline=True)
    embed.add_field(name="SL", value=f"`{sl:.5f}`", inline=True)
    embed.add_field(name="TP", value=f"`{tp:.5f}`", inline=True)
    embed.add_field(name="Lot", value=f"`{lot}`", inline=True)
    embed.add_field(name="Status", value="`OPEN`", inline=True)
    
    if message:
        clean_message = add_emojis_to_message(message.replace("\\n", "\n"), action)
        embed.description = clean_message
    
    embed.set_footer(text=f"Ticket: #{ticket} | Will auto-remove when closed")
    
    return embed


def create_closed_trade_embed(data):
                                                            
    action = data.get("action", "CLOSE")
    symbol = data.get("symbol", "N/A")
    price = data.get("price", 0)
    lot = data.get("lot", 0.01)
    ticket = data.get("ticket", 0)
    balance = data.get("balance", 0)
    equity = data.get("equity", 0)
    profit = data.get("profit", 0)
    message = data.get("message", "")
    
                             
    is_profit = profit >= 0
    color = 0x00FF00 if is_profit else 0xFF0000
    result_emoji = "✅" if is_profit else "❌"
    profit_str = f"+€{profit:.2f}" if is_profit else f"-€{abs(profit):.2f}"
    
    embed = discord.Embed(
        title="📊 FOREX AUTO TRADE",
        color=color,
        timestamp=datetime.utcnow()
    )
    
    trade_type = data.get("type", "")
    if not trade_type:
        original_action = data.get("original_action", "")
        if original_action in ["BUY", "SELL"]:
            trade_type = original_action
        else:
            for trade in open_trades:
                if trade.get("ticket") == ticket:
                    trade_type = trade.get("type", "")
                    break
    
    embed.add_field(name="Pair", value=f"`{symbol}`", inline=False)
    embed.add_field(name="Type", value=f"`{trade_type if trade_type else 'N/A'}`", inline=True)
    embed.add_field(name="Close", value=f"`{price:.5f}`", inline=True)
    embed.add_field(name="Lot", value=f"`{lot}`", inline=True)
    embed.add_field(name="Status", value="`CLOSED`", inline=True)
    embed.add_field(name="Profit", value=f"**`{profit_str}`**", inline=True)
    
    if message:
        clean_message = add_emojis_to_message(message.replace("\\n", "\n"), action)
        embed.description = clean_message
    
                                
    if balance > 0:
        drawdown = ((balance - equity) / balance * 100) if balance > 0 else 0
        dd_emoji = "🟢" if drawdown < 10 else ("🟡" if drawdown < 15 else "🔴")
        embed.set_footer(
            text=f"Ticket: #{ticket} | Balance: €{balance:.2f} | Equity: €{equity:.2f} | {dd_emoji} DD: {drawdown:.1f}%"
        )
    else:
        embed.set_footer(text=f"Ticket: #{ticket}")
    
    return embed


def create_gold_signal_embed(signal_type, entry, sl, tp1, tp2, tp3, analysis=""):
                                                      
    color = 0xFFD700
    
    embed = discord.Embed(
        title="🥇 GOLD SIGNAL (VIP)",
        color=color,
        timestamp=datetime.utcnow()
    )
    
    embed.add_field(name="Pair", value="`XAUUSD`", inline=False)
    embed.add_field(name="Type", value=f"`{signal_type}`", inline=True)
    embed.add_field(name="Entry", value=f"`{entry:.2f}`", inline=True)
    embed.add_field(name="SL", value=f"`{sl:.2f}`", inline=True)
    embed.add_field(name="TP1", value=f"`{tp1:.2f}`", inline=True)
    embed.add_field(name="TP2", value=f"`{tp2:.2f}`", inline=True)
    embed.add_field(name="TP3", value=f"`{tp3:.2f}`", inline=True)
    embed.add_field(name="Risk", value="`Conservative`", inline=True)
    
    if analysis:
        embed.description = analysis
    
    embed.set_footer(text="🔒 Gold VIP Exclusive | Manual Execution Required")
    return embed


def create_daily_gold_report_embed(report_data):
                                                    
    date_str = report_data["date"].strftime("%Y-%m-%d")
    total_signals = len(report_data["signals"])
    
                                             
    if report_data["total_profit"] > 0:
        color = 0x00FF00
        result_emoji = "✅"
    elif report_data["total_profit"] < 0:
        color = 0xFF0000
        result_emoji = "❌"
    else:
        color = 0xFFFF00
        result_emoji = "➖"
    
    embed = discord.Embed(
        title=f"🥇 GOLD DAILY REPORT - {date_str}",
        description=f"**End of Day Performance Summary**",
        color=color,
        timestamp=datetime.utcnow()
    )
    
    embed.add_field(name="📊 Total Signals", value=f"`{total_signals}`", inline=True)
    embed.add_field(name="📈 Total Pips", value=f"`{report_data['total_pips']:.1f}`", inline=True)
    embed.add_field(
        name=f"{result_emoji} Total Profit",
        value=f"**`€{report_data['total_profit']:.2f}`**",
        inline=True
    )
    
                      
    embed.add_field(name="🎯 TP1 Hit", value=f"`{report_data['tp1_hit']}`", inline=True)
    embed.add_field(name="🎯 TP2 Hit", value=f"`{report_data['tp2_hit']}`", inline=True)
    embed.add_field(name="🎯 TP3 Hit", value=f"`{report_data['tp3_hit']}`", inline=True)
    
    embed.add_field(name="🛑 SL Hit", value=f"`{report_data['sl_hit']}`", inline=True)
    
                          
    total_closed = report_data['tp1_hit'] + report_data['tp2_hit'] + report_data['tp3_hit'] + report_data['sl_hit']
    if total_closed > 0:
        wins = report_data['tp1_hit'] + report_data['tp2_hit'] + report_data['tp3_hit']
        win_rate = (wins / total_closed) * 100
        embed.add_field(name="📊 Win Rate", value=f"`{win_rate:.1f}%`", inline=True)
    else:
        embed.add_field(name="📊 Win Rate", value="`N/A`", inline=True)
    
    embed.set_footer(text="🔒 Gold VIP Performance Tracking")
    return embed


def create_status_embed(status):
                                         
    dd = status.get("drawdown", 0)
    dd_color = 0x00FF00 if dd < 10 else (0xFFFF00 if dd < 15 else 0xFF0000)
    
    embed = discord.Embed(
        title="📊 Account Status - Reliable Trader",
        description=f"**Strategy:** MonsterFX Pullback (Conservative)\n**Pairs:** `{', '.join(TRADING_PAIRS)}`",
        color=dd_color,
        timestamp=datetime.utcnow()
    )
    
    embed.add_field(name="💰 Balance", value=f"`€{status.get('balance', 0):.2f}`", inline=True)
    embed.add_field(name="📊 Equity", value=f"`€{status.get('equity', 0):.2f}`", inline=True)
    embed.add_field(name="📉 Drawdown", value=f"`{dd:.2f}%`", inline=True)
    embed.add_field(name="💳 Margin", value=f"`€{status.get('margin', 0):.2f}`", inline=True)
    embed.add_field(name="💵 Free Margin", value=f"`€{status.get('free_margin', 0):.2f}`", inline=True)
    embed.add_field(name="📈 Open Trades", value=f"`{status.get('open_trades', 0)}/{MAX_CONCURRENT_TRADES}`", inline=True)
    
    trading_status = "🟢 Active" if status.get("trading_enabled", True) else "🔴 Stopped"
    embed.add_field(name="🤖 Bot Status", value=trading_status, inline=True)
    
    if daily_trading_stats["date"] == datetime.now().date():
        embed.add_field(name="📊 Trades Today", value=f"`{daily_trading_stats['forex_trades_count']}/{MAX_FOREX_TRADES_PER_DAY}`", inline=True)
        daily_pnl = daily_trading_stats.get("daily_profit_loss", 0)
        pnl_emoji = "🟢" if daily_pnl >= 0 else "🔴"
        embed.add_field(name=f"{pnl_emoji} Daily P/L", value=f"`€{daily_pnl:.2f}`", inline=True)
    
    if status.get("last_update"):
        embed.set_footer(text=f"Last Update: {status['last_update']}")
    
    return embed


                                          
@bot.event
async def on_ready():
    global daily_trading_stats, gold_signals_today
    
    print(f"Bot is online as {bot.user}")
    print(f"Connected to {len(bot.guilds)} server(s)")
    print(f"Trading pairs: {', '.join(TRADING_PAIRS)}")
    print(f"Open Trades Channel: {OPEN_TRADES_CHANNEL}")
    print(f"Closed Trades Channel: {CLOSED_TRADES_CHANNEL}")
    print(f"Gold Report Channel: {GOLD_REPORT_CHANNEL}")
    
    current_date = datetime.now().date()
    
    if daily_trading_stats["date"] != current_date:
        if account_status.get("balance", 0) > 0:
            daily_trading_stats["starting_balance"] = account_status["balance"]
        daily_trading_stats = {
            "date": current_date,
            "forex_trades_count": 0,
            "daily_profit_loss": 0.0,
            "starting_balance": account_status.get("balance", 0)
        }
        print(f"Daily counters reset for {current_date}")
    
    if gold_signals_today["date"] != current_date:
        gold_signals_today = {
            "signals": [],
            "total_pips": 0,
            "total_profit": 0,
            "tp1_hit": 0,
            "tp2_hit": 0,
            "tp3_hit": 0,
            "sl_hit": 0,
            "date": current_date
        }
        print(f"Gold signals counter reset for {current_date}")
    
    try:
        synced = await bot.tree.sync()
        print(f"Synced {len(synced)} slash command(s)")
    except Exception as e:
        print(f"Failed to sync commands: {e}")
    
    process_trade_updates.start()
    daily_gold_report.start()
    reset_daily_counters.start()
    print("Trade update processor started")
    print("Daily Gold report scheduler started")
    print("Daily counter reset scheduler started")


                                              
@bot.tree.command(name="gold", description="[MANUAL] Send custom Gold signal (auto-signals are generated automatically)")
@app_commands.describe(
    direction="BUY or SELL",
    entry="Entry price",
    sl="Stop Loss price",
    tp1="Take Profit 1 (Safe)",
    tp2="Take Profit 2 (Target)",
    tp3="Take Profit 3 (Extended)",
    analysis="Optional analysis text"
)
@app_commands.checks.has_permissions(administrator=True)
async def gold_command(
    interaction: discord.Interaction,
    direction: str,
    entry: str,
    sl: str,
    tp1: str,
    tp2: str,
    tp3: str,
    analysis: str = ""
):
    global gold_signals_today
    
    direction = direction.upper()
    if direction not in ["BUY", "SELL"]:
        await interaction.response.send_message("❌ Direction must be BUY or SELL", ephemeral=True)
        return
    
    if GOLD_SIGNALS_CHANNEL == 0:
        await interaction.response.send_message("❌ Gold signals channel not configured", ephemeral=True)
        return
    
    channel = bot.get_channel(GOLD_SIGNALS_CHANNEL)
    if channel is None:
        await interaction.response.send_message("❌ Gold signals channel not found", ephemeral=True)
        return
    
    if gold_signals_today["date"] != datetime.now().date():
        gold_signals_today = {
            "signals": [],
            "total_pips": 0,
            "total_profit": 0,
            "tp1_hit": 0,
            "tp2_hit": 0,
            "tp3_hit": 0,
            "sl_hit": 0,
            "date": datetime.now().date()
        }
    
    if len(gold_signals_today["signals"]) >= MAX_GOLD_SIGNALS_PER_DAY:
        await interaction.response.send_message(f"❌ Maximum {MAX_GOLD_SIGNALS_PER_DAY} Gold signals per day reached. Please try again tomorrow.", ephemeral=True)
        return
    
    try:
        entry_f = float(entry)
        sl_f = float(sl)
        tp1_f = float(tp1)
        tp2_f = float(tp2)
        tp3_f = float(tp3)
    except ValueError:
        await interaction.response.send_message("❌ Invalid price format", ephemeral=True)
        return
    
    gold_role = interaction.guild.get_role(GOLD_VIP_ROLE) if GOLD_VIP_ROLE > 0 else None
    embed = create_gold_signal_embed(direction, entry_f, sl_f, tp1_f, tp2_f, tp3_f, analysis)
    
    ping_text = gold_role.mention if gold_role else ""
    await channel.send(content=ping_text, embed=embed)
    
                            
    gold_signals_today["signals"].append({
        "direction": direction,
        "entry": entry_f,
        "sl": sl_f,
        "tp1": tp1_f,
        "tp2": tp2_f,
        "tp3": tp3_f,
        "time": datetime.now()
    })
    
    await interaction.response.send_message(f"✅ Gold signal sent to VIP channel! ({len(gold_signals_today['signals'])}/{MAX_GOLD_SIGNALS_PER_DAY} today)", ephemeral=True)


@bot.tree.command(name="goldtp", description="[OPTIONAL] Manual override - TP/SL is auto-tracked by price monitor")
@app_commands.describe(result="TP1, TP2, TP3, or SL", pips="Pips gained/lost", profit="Profit in EUR")
@app_commands.checks.has_permissions(administrator=True)
async def gold_tp_command(
    interaction: discord.Interaction,
    result: str,
    pips: float,
    profit: float
):
    result = result.upper()
    if result not in ["TP1", "TP2", "TP3", "SL"]:
        await interaction.response.send_message("❌ Result must be TP1, TP2, TP3, or SL", ephemeral=True)
        return
    
    if result == "TP1":
        gold_signals_today["tp1_hit"] += 1
    elif result == "TP2":
        gold_signals_today["tp2_hit"] += 1
    elif result == "TP3":
        gold_signals_today["tp3_hit"] += 1
    elif result == "SL":
        gold_signals_today["sl_hit"] += 1
    
    gold_signals_today["total_pips"] += pips
    gold_signals_today["total_profit"] += profit
    
    await interaction.response.send_message(f"✅ Recorded {result}: {pips} pips, €{profit:.2f}", ephemeral=True)


@bot.tree.command(name="goldreport", description="Send Gold daily report now")
@app_commands.checks.has_permissions(administrator=True)
async def gold_report_command(interaction: discord.Interaction):
    await send_daily_gold_report()
    await interaction.response.send_message("✅ Gold daily report sent!", ephemeral=True)


@bot.tree.command(name="status", description="Show account status")
async def status_command(interaction: discord.Interaction):
    embed = create_status_embed(account_status)
    await interaction.response.send_message(embed=embed)


@bot.tree.command(name="trades", description="List all open trades")
async def trades_command(interaction: discord.Interaction):
    if not open_trades:
        embed = discord.Embed(
            title="📋 Open Trades",
            description="No open trades at the moment.",
            color=0x808080,
            timestamp=datetime.utcnow()
        )
        embed.set_footer(text=f"Strategy: EMA 21/50 + Trend Filter")
        await interaction.response.send_message(embed=embed)
        return
    
    embed = discord.Embed(
        title=f"📋 Open Trades ({len(open_trades)})",
        color=0x00BFFF,
        timestamp=datetime.utcnow()
    )
    
    for trade in open_trades[:10]:
        emoji = "🟢" if trade.get("type") == "BUY" else "🔴"
        profit = trade.get("profit", 0)
        profit_emoji = "📈" if profit >= 0 else "📉"
        profit_str = f"+€{profit:.2f}" if profit >= 0 else f"-€{abs(profit):.2f}"
        
        embed.add_field(
            name=f"{emoji} #{trade.get('ticket', 'N/A')} - {trade.get('symbol', 'N/A')}",
            value=f"Type: `{trade.get('type', 'N/A')}` | Lot: `{trade.get('lot', 0.01)}` | {profit_emoji} `{profit_str}`",
            inline=False
        )
    
    embed.set_footer(text=f"Strategy: EMA 21/50 + Trend Filter + Trailing Stop")
    await interaction.response.send_message(embed=embed)


@bot.tree.command(name="addsub", description="Add subscriber role to a user")
@app_commands.describe(user="User to add subscriber role to")
@app_commands.checks.has_permissions(administrator=True)
async def add_subscriber(interaction: discord.Interaction, user: discord.Member):
    if SUBSCRIBER_ROLE == 0:
        await interaction.response.send_message("❌ Subscriber role not configured", ephemeral=True)
        return
    
    role = interaction.guild.get_role(SUBSCRIBER_ROLE)
    if role is None:
        await interaction.response.send_message("❌ Subscriber role not found", ephemeral=True)
        return
    
    if role in user.roles:
        await interaction.response.send_message(f"❌ {user.mention} already has the subscriber role", ephemeral=True)
        return
    
    await user.add_roles(role)
    await interaction.response.send_message(f"✅ Added subscriber role to {user.mention}")


@bot.tree.command(name="removesub", description="Remove subscriber role from a user")
@app_commands.describe(user="User to remove subscriber role from")
@app_commands.checks.has_permissions(administrator=True)
async def remove_subscriber(interaction: discord.Interaction, user: discord.Member):
    if SUBSCRIBER_ROLE == 0:
        await interaction.response.send_message("❌ Subscriber role not configured", ephemeral=True)
        return
    
    role = interaction.guild.get_role(SUBSCRIBER_ROLE)
    if role is None:
        await interaction.response.send_message("❌ Subscriber role not found", ephemeral=True)
        return
    
    if role not in user.roles:
        await interaction.response.send_message(f"❌ {user.mention} doesn't have the subscriber role", ephemeral=True)
        return
    
    await user.remove_roles(role)
    await interaction.response.send_message(f"✅ Removed subscriber role from {user.mention}")


                                                 
async def send_daily_gold_report():
                                                
    global gold_signals_today
    
    channel = bot.get_channel(GOLD_REPORT_CHANNEL)
    if channel is None:
        print(f"Could not find Gold report channel {GOLD_REPORT_CHANNEL}")
        return
    
    embed = create_daily_gold_report_embed(gold_signals_today)
    
    gold_role = None
    if GOLD_VIP_ROLE > 0:
        for guild in bot.guilds:
            gold_role = guild.get_role(GOLD_VIP_ROLE)
            if gold_role:
                break
    
    ping_text = gold_role.mention if gold_role else ""
    await channel.send(content=ping_text, embed=embed)
    
                        
    gold_signals_today = {
        "signals": [],
        "total_pips": 0,
        "total_profit": 0,
        "tp1_hit": 0,
        "tp2_hit": 0,
        "tp3_hit": 0,
        "sl_hit": 0,
        "date": datetime.now().date()
    }


@tasks.loop(time=time(hour=0, minute=0))
async def reset_daily_counters():
    global daily_trading_stats, gold_signals_today
    
    current_date = datetime.now().date()
    if daily_trading_stats["date"] != current_date:
        if account_status.get("balance", 0) > 0:
            daily_trading_stats["starting_balance"] = account_status["balance"]
        daily_trading_stats = {
            "date": current_date,
            "forex_trades_count": 0,
            "daily_profit_loss": 0.0,
            "starting_balance": account_status.get("balance", 0)
        }
        print(f"Daily counters reset for {current_date}")


@tasks.loop(time=time(hour=21, minute=0))                                 
async def daily_gold_report():
                                              
    await send_daily_gold_report()


                                                      
@tasks.loop(seconds=1)
async def process_trade_updates():
    global trade_updates_queue, open_trade_messages
    
    with _queue_lock:
        if not trade_updates_queue:
            return
        updates = trade_updates_queue.copy()
        trade_updates_queue.clear()
    
    for update in updates:
        try:
            action = update.get("action", "")
            update_type = update.get("type", "")
            ticket = update.get("ticket", 0)
            symbol = update.get("symbol", "")
            
                                                                              
            if update_type == "GOLD_SIGNAL":
                if gold_signals_today["date"] != datetime.now().date():
                    gold_signals_today = {
                        "signals": [],
                        "total_pips": 0,
                        "total_profit": 0,
                        "tp1_hit": 0,
                        "tp2_hit": 0,
                        "tp3_hit": 0,
                        "sl_hit": 0,
                        "date": datetime.now().date()
                    }
                
                if len(gold_signals_today["signals"]) >= MAX_GOLD_SIGNALS_PER_DAY:
                    print(f"⚠️ Gold signal rejected: Maximum {MAX_GOLD_SIGNALS_PER_DAY} signals per day reached")
                    continue
                
                if GOLD_SIGNALS_CHANNEL > 0:
                    gold_channel = bot.get_channel(GOLD_SIGNALS_CHANNEL)
                    if gold_channel:
                        direction = update.get("direction", "BUY")
                        entry = update.get("entry", 0)
                        sl = update.get("sl", 0)
                        tp1 = update.get("tp1", 0)
                        tp2 = update.get("tp2", 0)
                        tp3 = update.get("tp3", 0)
                        rsi = update.get("rsi", 0)
                        
                        analysis = f"RSI: {rsi:.1f} | Auto-generated from EMA 21/50 crossover + trend filter"
                        embed = create_gold_signal_embed(direction, entry, sl, tp1, tp2, tp3, analysis)
                        
                        gold_role = None
                        if GOLD_VIP_ROLE > 0:
                            gold_role = gold_channel.guild.get_role(GOLD_VIP_ROLE)
                        
                        ping_text = gold_role.mention if gold_role else ""
                        await gold_channel.send(content=ping_text, embed=embed)
                        print(f"Posted Gold Signal: {direction} @ {entry} ({len(gold_signals_today['signals'])+1}/{MAX_GOLD_SIGNALS_PER_DAY} today)")
                
                continue
            
                                                                                   
            if update_type == "GOLD_TP_HIT":
                if GOLD_SIGNALS_CHANNEL > 0:
                    gold_channel = bot.get_channel(GOLD_SIGNALS_CHANNEL)
                    if gold_channel:
                        result = update.get("result", "")
                        entry = update.get("entry", 0)
                        hit_price = update.get("hit_price", 0)
                        pips = update.get("pips", 0)
                        profit = update.get("profit", 0)
                        
                                                
                        if result == "SL":
                            color = 0xFF0000
                            emoji = "🛑"
                            title = "GOLD STOP LOSS HIT"
                        else:
                            color = 0x00FF00
                            emoji = "🎯"
                            title = f"GOLD {result} HIT"
                        
                        embed = discord.Embed(
                            title=f"{emoji} {title}",
                            color=color,
                            timestamp=datetime.utcnow()
                        )
                        
                        embed.add_field(name="📊 Pair", value="`XAUUSD`", inline=True)
                        embed.add_field(name="📍 Entry", value=f"`{entry:.2f}`", inline=True)
                        embed.add_field(name="🎯 Hit Price", value=f"`{hit_price:.2f}`", inline=True)
                        
                        pips_emoji = "📈" if pips >= 0 else "📉"
                        embed.add_field(name=f"{pips_emoji} Pips", value=f"`{pips:+.1f}`", inline=True)
                        
                        profit_emoji = "💰" if profit >= 0 else "💸"
                        profit_str = f"+€{profit:.2f}" if profit >= 0 else f"-€{abs(profit):.2f}"
                        embed.add_field(name=f"{profit_emoji} Profit", value=f"**`{profit_str}`**", inline=True)
                        
                        embed.set_footer(text="🔒 Gold VIP | Auto-tracked by price monitor")
                        
                        gold_role = None
                        if GOLD_VIP_ROLE > 0:
                            gold_role = gold_channel.guild.get_role(GOLD_VIP_ROLE)
                        
                        ping_text = gold_role.mention if gold_role else ""
                        await gold_channel.send(content=ping_text, embed=embed)
                        print(f"Posted Gold {result} hit: {pips} pips")
                
                continue
            
                                           
            if action in ["BUY", "SELL"]:
                if daily_trading_stats["date"] != datetime.now().date():
                    if account_status.get("balance", 0) > 0:
                        daily_trading_stats["starting_balance"] = account_status["balance"]
                    daily_trading_stats = {
                        "date": datetime.now().date(),
                        "forex_trades_count": 0,
                        "daily_profit_loss": 0.0,
                        "starting_balance": account_status.get("balance", 0)
                    }
                
                daily_trading_stats["forex_trades_count"] += 1
                                             
                open_channel = bot.get_channel(OPEN_TRADES_CHANNEL)
                if open_channel:
                    embed = create_open_trade_embed(update)
                    sub_role = open_channel.guild.get_role(SUBSCRIBER_ROLE) if SUBSCRIBER_ROLE > 0 else None
                    ping_text = sub_role.mention if sub_role else ""
                    
                    msg = await open_channel.send(content=ping_text, embed=embed)
                    open_trade_messages[ticket] = msg.id
                    print(f"Posted OPEN: {action} {symbol} #{ticket} ({daily_trading_stats['forex_trades_count']}/{MAX_FOREX_TRADES_PER_DAY} today)")
            
                                  
            elif action == "CLOSE":
                profit = update.get("profit", 0)
                if daily_trading_stats["date"] == datetime.now().date():
                    daily_trading_stats["daily_profit_loss"] += profit
                
                if ticket in open_trade_messages:
                    try:
                        open_channel = bot.get_channel(OPEN_TRADES_CHANNEL)
                        if open_channel:
                            msg = await open_channel.fetch_message(open_trade_messages[ticket])
                            await msg.delete()
                            print(f"Deleted open trade message for #{ticket}")
                    except Exception as e:
                        print(f"Could not delete open trade message: {e}")
                    del open_trade_messages[ticket]
                
                                                     
                if CLOSED_TRADES_CHANNEL > 0:
                    closed_channel = bot.get_channel(CLOSED_TRADES_CHANNEL)
                    if closed_channel:
                        embed = create_closed_trade_embed(update)
                        await closed_channel.send(embed=embed)
                        print(f"Posted CLOSE: {symbol} #{ticket} | Daily P/L: €{daily_trading_stats.get('daily_profit_loss', 0):.2f}")
            
                                          
            elif action in ["SYSTEM", "ALERT", "DRAWDOWN"]:
                if CLOSED_TRADES_CHANNEL > 0:
                    channel = bot.get_channel(CLOSED_TRADES_CHANNEL)
                    if channel:
                        color = {"SYSTEM": 0x0099FF, "ALERT": 0xFF6600, "DRAWDOWN": 0xFF0000}.get(action, 0x808080)
                        emoji = {"SYSTEM": "🔵", "ALERT": "🟠", "DRAWDOWN": "⚠️"}.get(action, "⚪")
                        
                        embed = discord.Embed(
                            title=f"{emoji} {action} - {symbol}",
                            color=color,
                            timestamp=datetime.utcnow()
                        )
                        
                        message = update.get("message", "")
                        if message:
                            embed.description = add_emojis_to_message(message.replace("\\n", "\n"), action)
                        
                        sub_role = channel.guild.get_role(SUBSCRIBER_ROLE) if SUBSCRIBER_ROLE > 0 else None
                        ping_text = sub_role.mention if sub_role else ""
                        
                        await channel.send(content=ping_text, embed=embed)
                        print(f"Posted: {action} {symbol}")
            
        except Exception as e:
            print(f"Error posting update: {e}")


                                                   
def safe_parse_json(raw_data):
                                                            
    if not raw_data:
        return None
    
    try:
        return json.loads(raw_data)
    except json.JSONDecodeError:
        pass
    
    try:
        cleaned = re.sub(r'[\x00-\x1f\x7f-\x9f]', '', raw_data)
        cleaned = cleaned.strip()
        
        if not cleaned.endswith('}'):
            if '"time":"' in cleaned and not cleaned.endswith('"'):
                cleaned += '"}'
            elif cleaned.endswith('"'):
                cleaned += '}'
            elif cleaned.endswith(','):
                cleaned = cleaned[:-1] + '}'
            else:
                cleaned += '"}'
        
        return json.loads(cleaned)
    except:
        return None


                                         
app = Flask(__name__)


@app.route("/health", methods=["GET"])
def health_check():
    return jsonify({
        "status": "healthy",
        "bot_online": bot.is_ready(),
        "trading_pairs": TRADING_PAIRS,
        "strategy": "EMA 21/50 + Trend Filter + RSI + Trailing Stop",
        "trading_enabled": account_status.get("trading_enabled", True),
        "version": "5.0"
    }), 200


@app.route("/trade", methods=["POST"])
def receive_trade():
    global trade_updates_queue, account_status, open_trades, daily_trading_stats
    
    try:
        data = None
        try:
            data = request.json
        except Exception:
            raw_data = request.get_data(as_text=True)
            data = safe_parse_json(raw_data)
        
        if data is None:
            return jsonify({"error": "No data received"}), 400
        
        if data.get("secret") != SECRET_KEY:
            return jsonify({"error": "Invalid secret"}), 401
        
        action = data.get("action", "")
        
        if action in ["BUY", "SELL"]:
            if daily_trading_stats["date"] != datetime.now().date():
                if account_status.get("balance", 0) > 0:
                    daily_trading_stats["starting_balance"] = account_status["balance"]
                daily_trading_stats = {
                    "date": datetime.now().date(),
                    "forex_trades_count": 0,
                    "daily_profit_loss": 0.0,
                    "starting_balance": account_status.get("balance", 0)
                }
            
            open_trades_count = data.get("open_trades_count", account_status.get("open_trades", 0))
            
            if open_trades_count >= MAX_CONCURRENT_TRADES:
                return jsonify({
                    "error": f"Maximum {MAX_CONCURRENT_TRADES} concurrent trades limit reached",
                    "rejected": True
                }), 429
            
            if daily_trading_stats["forex_trades_count"] >= MAX_FOREX_TRADES_PER_DAY:
                return jsonify({
                    "error": f"Maximum {MAX_FOREX_TRADES_PER_DAY} trades per day limit reached",
                    "rejected": True
                }), 429
        
        if "balance" in data:
            account_status["balance"] = data.get("balance", 0)
            account_status["equity"] = data.get("equity", 0)
            account_status["margin"] = data.get("margin", 0)
            account_status["free_margin"] = data.get("free_margin", 0)
            account_status["open_trades"] = data.get("open_trades_count", 0)
            account_status["last_update"] = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            
            if account_status["balance"] > 0:
                account_status["drawdown"] = ((account_status["balance"] - account_status["equity"]) / account_status["balance"]) * 100
                
                if account_status["drawdown"] >= MAX_DRAWDOWN_PERCENT:
                    account_status["trading_enabled"] = False
                    print(f"⚠️ TRADING STOPPED: Drawdown {account_status['drawdown']:.2f}% >= {MAX_DRAWDOWN_PERCENT}%")
                    if CLOSED_TRADES_CHANNEL > 0:
                        with _queue_lock:
                            trade_updates_queue.append({
                                "action": "DRAWDOWN",
                                "symbol": "SYSTEM",
                                "message": f"⚠️ MAX DRAWDOWN REACHED: {account_status['drawdown']:.2f}% >= {MAX_DRAWDOWN_PERCENT}%\nTrading has been automatically stopped for safety."
                            })
        
        if daily_trading_stats["date"] == datetime.now().date() and daily_trading_stats.get("starting_balance", 0) > 0:
            current_balance = account_status.get("balance", 0)
            daily_loss = daily_trading_stats["starting_balance"] - current_balance
            daily_loss_percent = (daily_loss / daily_trading_stats["starting_balance"]) * 100 if daily_trading_stats["starting_balance"] > 0 else 0
            
            if daily_loss_percent >= MAX_DAILY_LOSS_PERCENT:
                account_status["trading_enabled"] = False
                print(f"⚠️ TRADING STOPPED: Daily loss {daily_loss_percent:.2f}% >= {MAX_DAILY_LOSS_PERCENT}%")
                if CLOSED_TRADES_CHANNEL > 0:
                    with _queue_lock:
                        trade_updates_queue.append({
                            "action": "DRAWDOWN",
                            "symbol": "SYSTEM",
                            "message": f"⚠️ DAILY LOSS PROTECTION: {daily_loss_percent:.2f}% daily loss >= {MAX_DAILY_LOSS_PERCENT}%\nTrading has been automatically stopped for safety."
                        })
        
        if "trades" in data:
            open_trades = data["trades"]
        
        if data.get("action") == "DRAWDOWN":
            account_status["trading_enabled"] = False
        
        if action in ["BUY", "SELL"] and not account_status.get("trading_enabled", True):
            return jsonify({
                "error": "Trading is currently disabled",
                "rejected": True
            }), 403
        
        with _queue_lock:
            trade_updates_queue.append(data)

        print(f"Received: {action} {data.get('symbol', '')}")
        return jsonify({"status": "success"}), 200
        
    except Exception as e:
        print(f"Error on /trade: {e}")
        return jsonify({"error": str(e)}), 500


@app.route("/gold_signal", methods=["POST"])
def receive_gold_signal():
                                                                                    
    global gold_signals_today
    
    try:
        data = None
        try:
            data = request.json
        except Exception:
            raw_data = request.get_data(as_text=True)
            data = safe_parse_json(raw_data)
        
        if data is None:
            return jsonify({"error": "No data received"}), 400
        
        if data.get("secret") != SECRET_KEY:
            return jsonify({"error": "Invalid secret"}), 401
        
        if gold_signals_today["date"] != datetime.now().date():
            gold_signals_today = {
                "signals": [],
                "total_pips": 0,
                "total_profit": 0,
                "tp1_hit": 0,
                "tp2_hit": 0,
                "tp3_hit": 0,
                "sl_hit": 0,
                "date": datetime.now().date()
            }
        
        if len(gold_signals_today["signals"]) >= MAX_GOLD_SIGNALS_PER_DAY:
            return jsonify({
                "error": f"Maximum {MAX_GOLD_SIGNALS_PER_DAY} Gold signals per day limit reached",
                "rejected": True
            }), 429
        
                                                   
        gold_signal_data = {
            "type": "GOLD_SIGNAL",
            "direction": data.get("direction", "BUY"),
            "entry": data.get("entry", 0),
            "sl": data.get("sl", 0),
            "tp1": data.get("tp1", 0),
            "tp2": data.get("tp2", 0),
            "tp3": data.get("tp3", 0),
            "rsi": data.get("rsi", 0)
        }
        
        with _queue_lock:
            trade_updates_queue.append(gold_signal_data)

        gold_signals_today["signals"].append({
            "direction": data.get("direction"),
            "entry": data.get("entry"),
            "sl": data.get("sl"),
            "tp1": data.get("tp1"),
            "tp2": data.get("tp2"),
            "tp3": data.get("tp3"),
            "time": datetime.now()
        })
        
        print(f"Received Gold Signal: {data.get('direction')} @ {data.get('entry')} ({len(gold_signals_today['signals'])}/{MAX_GOLD_SIGNALS_PER_DAY} today)")
        return jsonify({"status": "success"}), 200
        
    except Exception as e:
        print(f"Error on /gold_signal: {e}")
        return jsonify({"error": str(e)}), 500


@app.route("/gold_tp_hit", methods=["POST"])
def receive_gold_tp_hit():
                                                                             
    global gold_signals_today
    
    try:
        data = None
        try:
            data = request.json
        except Exception:
            raw_data = request.get_data(as_text=True)
            data = safe_parse_json(raw_data)
        
        if data is None:
            return jsonify({"error": "No data received"}), 400
        
        if data.get("secret") != SECRET_KEY:
            return jsonify({"error": "Invalid secret"}), 401
        
        result = data.get("result", "")                        
        pips = data.get("pips", 0)
        profit = data.get("profit", 0)
        entry = data.get("entry", 0)
        hit_price = data.get("hit_price", 0)
        
                                                 
        if result == "TP1":
            gold_signals_today["tp1_hit"] += 1
        elif result == "TP2":
            gold_signals_today["tp2_hit"] += 1
        elif result == "TP3":
            gold_signals_today["tp3_hit"] += 1
        elif result == "SL":
            gold_signals_today["sl_hit"] += 1
        
        gold_signals_today["total_pips"] += pips
        gold_signals_today["total_profit"] += profit
        
                                        
        tp_hit_data = {
            "type": "GOLD_TP_HIT",
            "result": result,
            "entry": entry,
            "hit_price": hit_price,
            "pips": pips,
            "profit": profit
        }
        with _queue_lock:
            trade_updates_queue.append(tp_hit_data)

        print(f"Gold {result} HIT: {pips} pips, EUR{profit:.2f}")
        return jsonify({"status": "success"}), 200
        
    except Exception as e:
        print(f"Error on /gold_tp_hit: {e}")
        return jsonify({"error": str(e)}), 500


@app.route("/status", methods=["POST"])
def update_status():
    global account_status, open_trades
    
    try:
        data = None
        try:
            data = request.json
        except Exception:
            raw_data = request.get_data(as_text=True)
            data = safe_parse_json(raw_data)
        
        if data is None:
            return jsonify({"error": "No data received"}), 400
        
        if data.get("secret") != SECRET_KEY:
            return jsonify({"error": "Invalid secret"}), 401
        
        account_status["balance"] = data.get("balance", 0)
        account_status["equity"] = data.get("equity", 0)
        account_status["margin"] = data.get("margin", 0)
        account_status["free_margin"] = data.get("free_margin", 0)
        account_status["open_trades"] = data.get("open_trades_count", 0)
        account_status["trading_enabled"] = data.get("trading_enabled", True)
        account_status["last_update"] = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        
        if account_status["balance"] > 0:
            account_status["drawdown"] = ((account_status["balance"] - account_status["equity"]) / account_status["balance"]) * 100
        
        if "trades" in data:
            open_trades = data["trades"]
        
        return jsonify({"status": "success"}), 200
        
    except Exception as e:
        print(f"Error on /status: {e}")
        return jsonify({"error": str(e)}), 500


def run_flask():
    app.run(host="0.0.0.0", port=WEBHOOK_PORT, threaded=True, use_reloader=False)


                                    
def main():
    print("\n" + "="*55)
    print("  MONSTERFX RELIABLE TRADER v5.0")
    print("="*55)
    print(f"Pairs: {', '.join(TRADING_PAIRS)}")
    print(f"Strategy: MonsterFX Pullback (Conservative)")
    print(f"Max Forex Trades/Day: {MAX_FOREX_TRADES_PER_DAY}")
    print(f"Max Concurrent Trades: {MAX_CONCURRENT_TRADES}")
    print(f"Max Drawdown: {MAX_DRAWDOWN_PERCENT}%")
    print(f"Max Daily Loss: {MAX_DAILY_LOSS_PERCENT}%")
    print(f"Max Gold Signals/Day: {MAX_GOLD_SIGNALS_PER_DAY}")
    print(f"Webhook Port: {WEBHOOK_PORT}")
    print(f"Open Trades Channel: {OPEN_TRADES_CHANNEL}")
    print(f"Closed Trades Channel: {CLOSED_TRADES_CHANNEL}")
    print(f"Gold Report Channel: {GOLD_REPORT_CHANNEL}")
    
    if not BOT_TOKEN:
        print("ERROR: DISCORD_BOT_TOKEN not set")
        return
    
    flask_thread = threading.Thread(target=run_flask, daemon=True)
    flask_thread.start()
    print(f"\nAPI server started on port {WEBHOOK_PORT}")
    
    print("\nStarting Discord bot...")
    bot.run(BOT_TOKEN)


if __name__ == "__main__":
    main()