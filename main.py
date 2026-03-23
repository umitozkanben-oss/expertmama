"""
ExpertMAMA Cloud Backend v2
FastAPI — Contabo VPS Ubuntu 24
Port: 8765
"""

from fastapi import FastAPI, Request, HTTPException
from fastapi.middleware.cors import CORSMiddleware
import json, time, collections, threading

app = FastAPI(title="ExpertMAMA API", version="2.0")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

lock = threading.Lock()

bar_data       = {}   # "EURUSD_M15" → deque
tick_data      = {}
equity_history = collections.deque(maxlen=500)
open_positions = {}
trade_history  = collections.deque(maxlen=1000)
last_heartbeat = {}
connected_syms = set()

VALID_TF = {"M5","M15","H1","H4"}

@app.get("/")
def root(): return {"status":"ok"}

@app.get("/health")
def health():
    now = time.time()
    active = {s for s,t in last_heartbeat.items() if now-t < 30}
    return {"status":"ok","symbols":list(active),"uptime":int(now)}

@app.post("/tick")
async def recv_tick(request: Request):
    try:
        data = json.loads((await request.body()).decode("latin-1"))
    except Exception as e:
        raise HTTPException(400, str(e))
    sym = data.get("symbol","").upper().strip()
    if not sym: raise HTTPException(400,"symbol missing")
    with lock:
        tick_data[sym] = {**data, "symbol":sym}
        connected_syms.add(sym)
        last_heartbeat[sym] = time.time()
        equity_history.append({"t":int(time.time()),"v":data.get("equity",0)})
    return {"status":"ok"}

@app.post("/bars")
async def recv_bars(request: Request):
    try:
        data = json.loads((await request.body()).decode("latin-1"))
    except Exception as e:
        raise HTTPException(400, str(e))
    sym  = data.get("symbol","").upper().strip()
    tf   = data.get("tf","M15").upper().strip()
    bars = data.get("bars",[])
    if not sym or not bars: raise HTTPException(400,"missing")
    if tf not in VALID_TF: tf = "M15"
    key = sym + "_" + tf
    with lock:
        if key not in bar_data:
            bar_data[key] = collections.deque(maxlen=1000)
        existing = {b["t"] for b in bar_data[key]}
        for b in bars:
            if b.get("t") not in existing:
                bar_data[key].append(b)
        sorted_bars = sorted(bar_data[key], key=lambda x: x["t"])
        bar_data[key] = collections.deque(sorted_bars, maxlen=1000)
    return {"status":"ok"}

@app.post("/positions")
async def recv_positions(request: Request):
    try:
        data = json.loads((await request.body()).decode("latin-1"))
    except Exception as e:
        raise HTTPException(400, str(e))
    with lock:
        open_positions.clear()
        for pos in data.get("positions",[]):
            open_positions[str(pos.get("ticket"))] = pos
        # Ticket bazlı biriktir — aynı ticket gelirse güncelle
        existing = {d.get("ticket"): i for i, d in enumerate(trade_history)}
        for deal in data.get("history",[]):
            t = deal.get("ticket")
            if t in existing:
                # Güncelle (profit değişmiş olabilir)
                list(trade_history)[existing[t]].update(deal)
            else:
                trade_history.appendleft(deal)
                existing[t] = 0
    return {"status":"ok"}

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
            "server_time":    int(now),
        }

@app.get("/bars/{symbol}")
def get_bars(symbol: str, limit: int = 500, tf: str = "M15"):
    sym = symbol.upper()
    tf  = tf.upper()
    if tf not in VALID_TF: tf = "M15"
    key = sym + "_" + tf
    with lock:
        data = bar_data.get(key)
        if not data:
            return {"symbol":sym,"tf":tf,"bars":[],"count":0}
        bars = list(data)[-limit:]
        return {"symbol":sym,"tf":tf,"bars":bars,"count":len(bars)}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host="0.0.0.0", port=8765, reload=False)
