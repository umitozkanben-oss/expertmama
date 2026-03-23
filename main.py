"""
ExpertMAMA Cloud Backend
FastAPI — Contabo VPS Ubuntu 20/22
Port: 8765
"""

from fastapi import FastAPI, Request, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
import json, time, collections, threading
from datetime import datetime

app = FastAPI(title="ExpertMAMA API", version="1.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# ── VERİ DEPOSU ──
# Her sembol için son 2000 bar saklanır (RAM dostu)
MAX_BARS   = 2000
MAX_TICKS  = 500

lock = threading.Lock()

# { "EURUSD": deque([{t, o, h, l, c, v}, ...]) }
bar_data   = {}

# { "EURUSD": {"bid":..., "ask":..., "time":...} }
tick_data  = {}

# { "EURUSD": deque([{time, price}, ...]) }  — equity için
equity_history = collections.deque(maxlen=200)

# Açık pozisyonlar ve işlem geçmişi
open_positions = {}   # ticket → pos dict
trade_history  = collections.deque(maxlen=500)

# Bağlı semboller
connected_symbols = set()
last_heartbeat = {}

# ── DESTEKLENEN SEMBOLLER ──
ALLOWED_SYMBOLS = {
    # Majors
    "EURUSD","GBPUSD","USDJPY","USDCHF","AUDUSD","NZDUSD","USDCAD",
    # Minors
    "EURGBP","EURJPY","EURCHF","EURCAD","EURAUD","EURNZD",
    "GBPJPY","GBPCHF","GBPCAD","GBPAUD","GBPNZD",
    "AUDJPY","AUDCHF","AUDCAD","AUDNZD",
    "NZDJPY","NZDCHF","NZDCAD",
    "CADJPY","CADCHF","CHFJPY",
    # Emtialar & Kripto & Endeksler
    "XAUUSD","XAGUSD","BTCUSD","ETHUSD","US100","US500","GER40",
}

# ── ENDPOINTS ──

@app.get("/")
def root():
    return {"status": "ok", "service": "ExpertMAMA Cloud API", "time": int(time.time())}

@app.get("/health")
def health():
    return {
        "status":   "ok",
        "symbols":  list(connected_symbols),
        "uptime":   int(time.time()),
    }

# ── TICK VERİSİ (MT5 EA her tick'te POST atar) ──
@app.post("/tick")
async def receive_tick(request: Request):
    try:
        raw  = await request.body()
        text = raw.decode("latin-1")
        data = json.loads(text)
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Parse error: {e}")

    symbol = data.get("symbol", "").upper().strip()
    if not symbol:
        raise HTTPException(status_code=400, detail="symbol missing")

    with lock:
        tick_data[symbol] = {
            "symbol":  symbol,
            "bid":     data.get("bid", 0),
            "ask":     data.get("ask", 0),
            "spread":  data.get("spread", 0),
            "time":    data.get("time", int(time.time())),
            "balance": data.get("balance", 0),
            "equity":  data.get("equity", 0),
            "margin":  data.get("margin", 0),
            "free_margin": data.get("free_margin", 0),
            "currency": data.get("currency", "USD"),
        }
        connected_symbols.add(symbol)
        last_heartbeat[symbol] = time.time()

        # Equity geçmişi
        equity_history.append({
            "t": int(time.time()),
            "v": data.get("equity", 0),
        })

    return {"status": "ok"}

# ── BAR VERİSİ (EA her kapanan barda POST atar) ──
@app.post("/bars")
async def receive_bars(request: Request):
    try:
        raw  = await request.body()
        text = raw.decode("latin-1")
        data = json.loads(text)
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Parse error: {e}")

    symbol = data.get("symbol", "").upper().strip()
    bars   = data.get("bars", [])

    if not symbol or not bars:
        raise HTTPException(status_code=400, detail="symbol or bars missing")

    with lock:
        if symbol not in bar_data:
            bar_data[symbol] = collections.deque(maxlen=MAX_BARS)

        existing_times = {b["t"] for b in bar_data[symbol]}
        new_count = 0
        for b in bars:
            if b.get("t") not in existing_times:
                bar_data[symbol].append(b)
                new_count += 1

        # Zamana göre sırala
        sorted_bars = sorted(bar_data[symbol], key=lambda x: x["t"])
        bar_data[symbol] = collections.deque(sorted_bars, maxlen=MAX_BARS)

    return {"status": "ok", "added": new_count}

# ── POZİSYON VERİSİ ──
@app.post("/positions")
async def receive_positions(request: Request):
    try:
        raw  = await request.body()
        text = raw.decode("latin-1")
        data = json.loads(text)
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Parse error: {e}")

    with lock:
        open_positions.clear()
        for pos in data.get("positions", []):
            open_positions[str(pos.get("ticket"))] = pos

        for deal in data.get("history", []):
            trade_history.appendleft(deal)

    return {"status": "ok"}

# ── GET: DASHBOARD VERİSİ ──
@app.get("/data")
def get_data():
    with lock:
        # Bağlı sembolleri kontrol et (30sn timeout)
        now = time.time()
        active = {s for s, t in last_heartbeat.items() if now - t < 30}

        return {
            "ticks":          dict(tick_data),
            "symbols":        list(active),
            "equity_history": list(equity_history),
            "open_positions": list(open_positions.values()),
            "trade_history":  list(trade_history)[:100],
            "server_time":    int(now),
        }

@app.get("/bars/{symbol}")
def get_bars(symbol: str, limit: int = 500, tf: str = ""):
    sym = symbol.upper()
    key = sym + ("_" + tf if tf else "")
    with lock:
        # tf varsa o anahtara bak, yoksa düz sembol
        data = bar_data.get(key) or bar_data.get(sym)
        if not data:
            return {"symbol": sym, "bars": [], "count": 0}
        bars = list(data)
        return {
            "symbol": sym,
            "bars":   bars[-limit:],
            "count":  len(bars),
        }

@app.get("/ticks")
def get_ticks():
    with lock:
        return dict(tick_data)

if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host="0.0.0.0", port=8765, reload=False)
