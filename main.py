"""
ExpertMAMA Cloud Backend v3
FastAPI — Contabo VPS Ubuntu 24
Port: 8765
"""
from fastapi import FastAPI, Request, HTTPException
from fastapi.middleware.cors import CORSMiddleware
import json, time, collections, threading, os

app = FastAPI(title="ExpertMAMA API", version="3.0")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

lock = threading.Lock()

bar_data       = {}
tick_data      = {}
equity_history = collections.deque(maxlen=500)
open_positions = {}
trade_history  = collections.deque(maxlen=2000)
last_heartbeat = {}
connected_syms = set()

VALID_TF = {"M5","M15","H1","H4"}
SAVE_FILE = "/opt/expertmama/data.json"

# ── Kalıcı veri yükle ──
def load_persistent():
    global strategies, auto_mode, risk_settings
    try:
        if os.path.exists(SAVE_FILE):
            with open(SAVE_FILE, "r") as f:
                data = json.load(f)
                strategies    = data.get("strategies", {})
                auto_mode     = data.get("auto_mode", {"enabled": False})
                risk_settings.update(data.get("risk_settings", {}))
                print(f"Veri yüklendi: {len(strategies)} strateji, oto={auto_mode['enabled']}")
    except Exception as e:
        print(f"Veri yüklenemedi: {e}")

def save_persistent():
    try:
        with open(SAVE_FILE, "w") as f:
            json.dump({"strategies": strategies, "auto_mode": auto_mode, "risk_settings": risk_settings}, f)
    except Exception as e:
        print(f"Veri kaydedilemedi: {e}")

strategies = {}
auto_mode  = {"enabled": False}
risk_settings = {
    "enabled": False,
    "daily_loss_limit": 100.0,
    "max_open_positions": 10,
    "max_lot_per_trade": 1.0,
}
load_persistent()

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
            bar_data[key] = collections.deque(maxlen=3000)
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
                # 25 Mart 2026 öncesi işlemleri alma
                if deal.get("time",0) < 1742860800:
                    continue
                trade_history.appendleft(deal)
                existing.add(deal.get("ticket"))
    return {"status":"ok"}

# ── STRATEGIES ──
@app.get("/strategies")
def get_strategies():
    with lock:
        ma_strats   = [s for s in strategies.values() if s.get("type","MA")=="MA"]
        scalp_strats= [s for s in strategies.values() if s.get("type")=="SCALP"]
        return {
            "strategies":       ma_strats,
            "scalp_strategies": scalp_strats,
            "auto_mode":        auto_mode["enabled"],
            "risk_settings":    risk_settings.copy()
        }

@app.post("/strategies")
async def save_strategy(request: Request):
    try: data = json.loads((await request.body()).decode("latin-1"))
    except Exception as e: raise HTTPException(400, str(e))
    strat_id = data.get("id")
    if not strat_id: raise HTTPException(400,"id missing")
    with lock:
        strat_type = data.get("type","MA").upper()
        if strat_type == "SCALP":
            strategies[strat_id] = {
                "id":              strat_id,
                "type":            "SCALP",
                "symbol":          data.get("symbol","").upper(),
                "tf":              data.get("tf","M5").upper(),
                "lot":             float(data.get("lot",0.05)),
                "engulf_pct":      float(data.get("engulf_pct",1.0)),
                "min_engulf_pip":  float(data.get("min_engulf_pip",5.0)),
                "pullback_pct":    float(data.get("pullback_pct",0.5)),
                "pullback_bars":   int(data.get("pullback_bars",3)),
                "tp_pip":          float(data.get("tp_pip",10.0)),
                "tp_pct":          float(data.get("tp_pct",1.0)),
                "sl_pip":          float(data.get("sl_pip",10.0)),
                "use_ma_filter":   bool(data.get("use_ma_filter",False)),
                "ma_fast":         int(data.get("ma_fast",12)),
                "ma_slow":         int(data.get("ma_slow",26)),
                "ma_type":         data.get("ma_type","EMA"),
                "max_spread_pip":  float(data.get("max_spread_pip",0)),
                "active":          bool(data.get("active",True)),
                "created":         int(time.time()),
            }
        else:
            strategies[strat_id] = {
                "id":              strat_id,
                "type":            "MA",
                "symbol":          data.get("symbol","").upper(),
                "tf":              data.get("tf","M15").upper(),
                "fast":            int(data.get("fast",12)),
                "slow":            int(data.get("slow",26)),
                "ma_type":         data.get("ma_type","EMA"),
                "lot":             float(data.get("lot",0.05)),
                "sl_pip":          float(data.get("sl_pip",0)),
                "tp_pip":          float(data.get("tp_pip",0)),
                "atr_mult":        float(data.get("atr_mult",1.5)),
                "use_limit_entry": bool(data.get("use_limit_entry",False)),
                "proximity_pct":   float(data.get("proximity_pct",0.10)),
                "active":          bool(data.get("active",True)),
                "created":         int(time.time()),
            }
        save_persistent()
    return {"status":"ok","id":strat_id}

@app.delete("/strategies/{strat_id}")
def delete_strategy(strat_id: str):
    with lock:
        if strat_id in strategies:
            del strategies[strat_id]
        save_persistent()
    return {"status":"ok"}

@app.post("/strategies/{strat_id}/toggle")
def toggle_strategy(strat_id: str):
    with lock:
        if strat_id in strategies:
            strategies[strat_id]["active"] = not strategies[strat_id]["active"]
        save_persistent()
    return {"status":"ok"}

@app.post("/automode")
async def set_automode(request: Request):
    try: data = json.loads((await request.body()).decode("latin-1"))
    except Exception as e: raise HTTPException(400, str(e))
    with lock:
        auto_mode["enabled"] = bool(data.get("enabled", False))
        save_persistent()
    return {"status":"ok","auto_mode":auto_mode["enabled"]}

# ── DATA ──
@app.post("/clearhistory")
def clear_history():
    with lock:
        trade_history.clear()
        open_positions.clear()
    return {"status":"ok"}

# ── RISK ──
@app.get("/risk")
def get_risk():
    with lock:
        return risk_settings.copy()

@app.post("/risk")
async def set_risk(request: Request):
    try: data = json.loads((await request.body()).decode("latin-1"))
    except Exception as e: raise HTTPException(400, str(e))
    with lock:
        risk_settings.update({
            "daily_loss_limit": float(data.get("daily_loss_limit", risk_settings["daily_loss_limit"])),
            "max_open_positions": int(data.get("max_open_positions", risk_settings["max_open_positions"])),
            "max_lot_per_trade": float(data.get("max_lot_per_trade", risk_settings["max_lot_per_trade"])),
            "enabled": bool(data.get("enabled", risk_settings["enabled"])),
        })
        save_persistent()
    return {"status": "ok", "risk": risk_settings}

@app.get("/data")
def get_data():
    with lock:
        now = time.time()
        active = {s for s,t in last_heartbeat.items() if now-t < 30}
        # Günlük K/Z hesapla
        today_start = int(time.mktime(time.strptime(time.strftime("%Y-%m-%d"), "%Y-%m-%d")))
        daily_pnl = sum(d.get("profit", 0) for d in trade_history if d.get("time", 0) >= today_start)
        return {
            "ticks":          dict(tick_data),
            "symbols":        list(active),
            "equity_history": list(equity_history),
            "open_positions": list(open_positions.values()),
            "trade_history":  list(trade_history),
            "strategies":     [s for s in strategies.values() if s.get("type","MA")=="MA"],
            "scalp_strategies": [s for s in strategies.values() if s.get("type")=="SCALP"],
            "auto_mode":      auto_mode["enabled"],
            "risk_settings":  risk_settings.copy(),
            "daily_pnl":      round(daily_pnl, 2),
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
