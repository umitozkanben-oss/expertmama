"""
ExpertMAMA Cloud Backend v3
FastAPI — Contabo VPS Ubuntu 24
Port: 8765
"""
from fastapi import FastAPI, Request, HTTPException
from fastapi.middleware.cors import CORSMiddleware
import json, time, collections, threading

app = FastAPI(title="ExpertMAMA API", version="3.0")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

lock = threading.Lock()

bar_data       = {}   # "EURUSD_M15" → deque
tick_data      = {}   # "EURUSD" → tick dict (includes tick_value)
equity_history = collections.deque(maxlen=500)
open_positions = {}
trade_history  = collections.deque(maxlen=2000)
last_heartbeat = {}
connected_syms = set()

# Aktif stratejiler: { "strat_id": { symbol, tf, fast, slow, ma_type, lot, sl_pip, atr_mult, active } }
strategies     = {}
# Otomatik mod
auto_mode      = {"enabled": False}

VALID_TF = {"M5","M15","H1","H4"}

@app.get("/")
def root(): return {"status":"ok","version":"3.0"}

@app.get("/health")
def health():
    now = time.time()
    active = {s for s,t in last_heartbeat.items() if now-t < 30}
    return {"status":"ok","symbols":list(active),"uptime":int(now),"auto_mode":auto_mode["enabled"]}

# ── TICK ──
@app.post("/tick")
async def recv_tick(request: Request):
    try: data = json.loads((await request.body()).decode("latin-1"))
    except Exception as e: raise HTTPException(400, str(e))
    sym = data.get("symbol","").upper().strip()
    if not sym: raise HTTPException(400,"symbol missing")
    with lock:
        tick_data[sym] = {**data, "symbol": sym}
        connected_syms.add(sym)
        last_heartbeat[sym] = time.time()
        equity_history.append({"t":int(time.time()),"v":data.get("equity",0)})
    return {"status":"ok"}

# ── BARS ──
@app.post("/bars")
async def recv_bars(request: Request):
    try: data = json.loads((await request.body()).decode("latin-1"))
    except Exception as e: raise HTTPException(400, str(e))
    sym  = data.get("symbol","").upper().strip()
    tf   = data.get("tf","M15").upper().strip()
    bars = data.get("bars",[])
    if not sym or not bars: raise HTTPException(400,"missing")
    if tf not in VALID_TF: tf = "M15"
    key = sym + "_" + tf
    with lock:
        if key not in bar_data:
            bar_data[key] = collections.deque(maxlen=2000)
        existing = {b["t"] for b in bar_data[key]}
        for b in bars:
            if b.get("t") not in existing:
                bar_data[key].append(b)
        bar_data[key] = collections.deque(sorted(bar_data[key], key=lambda x: x["t"]), maxlen=2000)
    return {"status":"ok"}

# ── POSITIONS ──
@app.post("/positions")
async def recv_positions(request: Request):
    try: data = json.loads((await request.body()).decode("latin-1"))
    except Exception as e: raise HTTPException(400, str(e))
    with lock:
        open_positions.clear()
        for pos in data.get("positions",[]):
            open_positions[str(pos.get("ticket"))] = pos
        existing = {d.get("ticket") for d in trade_history}
        for deal in data.get("history",[]):
            if deal.get("ticket") not in existing:
                trade_history.appendleft(deal)
                existing.add(deal.get("ticket"))
    return {"status":"ok"}

# ── STRATEGIES ──
@app.get("/strategies")
def get_strategies():
    with lock:
        return {"strategies": list(strategies.values()), "auto_mode": auto_mode["enabled"]}

@app.post("/strategies")
async def save_strategy(request: Request):
    try: data = json.loads((await request.body()).decode("latin-1"))
    except Exception as e: raise HTTPException(400, str(e))
    strat_id = data.get("id")
    if not strat_id: raise HTTPException(400,"id missing")
    with lock:
        strategies[strat_id] = {
            "id":       strat_id,
            "symbol":   data.get("symbol","").upper(),
            "tf":       data.get("tf","M15").upper(),
            "fast":     int(data.get("fast",12)),
            "slow":     int(data.get("slow",26)),
            "ma_type":  data.get("ma_type","EMA"),
            "lot":      float(data.get("lot",0.05)),
            "sl_pip":   float(data.get("sl_pip",50)),
            "atr_mult": float(data.get("atr_mult",1.5)),
            "active":   bool(data.get("active",True)),
            "created":  int(time.time()),
        }
    return {"status":"ok","id":strat_id}

@app.delete("/strategies/{strat_id}")
def delete_strategy(strat_id: str):
    with lock:
        if strat_id in strategies:
            del strategies[strat_id]
    return {"status":"ok"}

@app.post("/strategies/{strat_id}/toggle")
def toggle_strategy(strat_id: str):
    with lock:
        if strat_id in strategies:
            strategies[strat_id]["active"] = not strategies[strat_id]["active"]
    return {"status":"ok"}

# ── AUTO MODE ──
@app.post("/automode")
async def set_automode(request: Request):
    try: data = json.loads((await request.body()).decode("latin-1"))
    except Exception as e: raise HTTPException(400, str(e))
    with lock:
        auto_mode["enabled"] = bool(data.get("enabled", False))
    return {"status":"ok","auto_mode":auto_mode["enabled"]}

# ── DATA ──
@app.get("/data")
def get_data():
    with lock:
        now = time.time()
        active = {s for s,t in last_heartbeat.items() if now-t < 30}
        return {
            "ticks":          dict(tick_data),
            "symbols":        list(active),
            "equity_history": list(equity_history),
            "open_positions": list(open_positions.values()),
            "trade_history":  list(trade_history),
            "strategies":     list(strategies.values()),
            "auto_mode":      auto_mode["enabled"],
            "server_time":    int(now),
        }

@app.get("/bars/{symbol}")
def get_bars(symbol: str, limit: int = 1000, tf: str = "M15"):
    sym = symbol.upper()
    tf  = tf.upper()
    if tf not in VALID_TF: tf = "M15"
    key = sym + "_" + tf
    with lock:
        data = bar_data.get(key)
        if not data: return {"symbol":sym,"tf":tf,"bars":[],"count":0}
        bars = list(data)[-limit:]
        return {"symbol":sym,"tf":tf,"bars":bars,"count":len(bars)}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host="0.0.0.0", port=8765, reload=False)
