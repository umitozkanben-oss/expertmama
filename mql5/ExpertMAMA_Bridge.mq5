//+------------------------------------------------------------------+
//|                                        ExpertMAMA_Bridge.mq5    |
//|  SADECE VERİ KÖPRÜSÜ — HİÇBİR İŞLEM AÇMAZ                     |
//+------------------------------------------------------------------+
#property copyright "Copyright 2000-2026, MetaQuotes Ltd."
#property version   "1.00"
#property description "MT5 → VPS veri köprüsü. İşlem açmaz."

string VPS_URL   = "http://94.250.203.232:8765";
input int TickEvery  = 3;
input int PosEvery   = 10;
input int TrackMagic = 0; // 0 = tüm işlemler

int      g_tick = 0, g_pos = 0;
bool     g_bars_sent = false;
datetime g_last_bar_m5  = 0;
datetime g_last_bar_m15 = 0;
datetime g_last_bar_h1  = 0;
datetime g_last_bar_h4  = 0;

int OnInit(void)
  {
   EventSetTimer(2);
   printf("ExpertMAMA Bridge başladı → " + VPS_URL);
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason) { EventKillTimer(); }

void OnTick(void)
  {
   g_tick++; g_pos++;
   if(g_tick >= TickEvery)  { SendTick();      g_tick = 0; }
   if(g_pos  >= PosEvery)   { SendPositions(); g_pos  = 0; }

   // Yeni bar kontrolü — her TF için
   datetime b;
   b = iTime(Symbol(), PERIOD_M5,  0); if(g_last_bar_m5  != 0 && b != g_last_bar_m5)  SendBars(PERIOD_M5,  500); g_last_bar_m5  = b;
   b = iTime(Symbol(), PERIOD_M15, 0); if(g_last_bar_m15 != 0 && b != g_last_bar_m15) SendBars(PERIOD_M15, 500); g_last_bar_m15 = b;
   b = iTime(Symbol(), PERIOD_H1,  0); if(g_last_bar_h1  != 0 && b != g_last_bar_h1)  SendBars(PERIOD_H1,  500); g_last_bar_h1  = b;
   b = iTime(Symbol(), PERIOD_H4,  0); if(g_last_bar_h4  != 0 && b != g_last_bar_h4)  SendBars(PERIOD_H4,  500); g_last_bar_h4  = b;
  }

void OnTimer(void)
  {
   if(!g_bars_sent)
     {
      SendBars(PERIOD_M5,  500);
      SendBars(PERIOD_M15, 500);
      SendBars(PERIOD_H1,  500);
      SendBars(PERIOD_H4,  500);
      SendPositions();
      g_bars_sent = true;
      printf("İlk bar verisi gönderildi (M5/M15/H1/H4).");
     }
  }

void OnTrade(void) { SendPositions(); }

//+------------------------------------------------------------------+
bool PostJSON(string endpoint, string body)
  {
   string headers = "Content-Type: application/json\r\n";
   char post[], result[]; string rh;
   int len = StringToCharArray(body, post, 0, WHOLE_ARRAY, CP_ACP);
   if(len > 0 && post[len-1] == 0) ArrayResize(post, len-1);
   int res = WebRequest("POST", VPS_URL + endpoint, headers, 5000, post, result, rh);
   if(res == -1 && GetLastError() == 4014)
      printf("Whitelist'e ekleyin: " + VPS_URL);
   return res != -1;
  }

//+------------------------------------------------------------------+
void SendTick()
  {
   double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
   double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
   double pt  = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   string json = "{";
   json += "\"symbol\":\""    + Symbol() + "\",";
   json += "\"bid\":"         + DoubleToString(bid, 5) + ",";
   json += "\"ask\":"         + DoubleToString(ask, 5) + ",";
   json += "\"spread\":"      + DoubleToString((ask-bid)/pt, 1) + ",";
   json += "\"balance\":"     + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE),   2) + ",";
   json += "\"equity\":"      + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY),    2) + ",";
   json += "\"margin\":"      + DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN),    2) + ",";
   json += "\"free_margin\":" + DoubleToString(AccountInfoDouble(ACCOUNT_FREEMARGIN),2) + ",";
   json += "\"currency\":\""  + AccountInfoString(ACCOUNT_CURRENCY) + "\",";
   json += "\"time\":"        + IntegerToString((long)TimeCurrent());
   json += "}";
   PostJSON("/tick", json);
  }

//+------------------------------------------------------------------+
void SendBars(ENUM_TIMEFRAMES tf, int count)
  {
   string tf_str;
   switch(tf)
     {
      case PERIOD_M5:  tf_str = "M5";  break;
      case PERIOD_M15: tf_str = "M15"; break;
      case PERIOD_H1:  tf_str = "H1";  break;
      case PERIOD_H4:  tf_str = "H4";  break;
      default:         tf_str = "M15"; break;
     }

   MqlRates rates[];
   int copied = CopyRates(Symbol(), tf, 0, count, rates);
   if(copied <= 0) return;

   string json = "{\"symbol\":\"" + Symbol() + "\",\"tf\":\"" + tf_str + "\",\"bars\":[";
   for(int i = 0; i < copied; i++)
     {
      if(i > 0) json += ",";
      json += "{";
      json += "\"t\":"  + IntegerToString((long)rates[i].time) + ",";
      json += "\"o\":"  + DoubleToString(rates[i].open,  5) + ",";
      json += "\"h\":"  + DoubleToString(rates[i].high,  5) + ",";
      json += "\"l\":"  + DoubleToString(rates[i].low,   5) + ",";
      json += "\"c\":"  + DoubleToString(rates[i].close, 5) + ",";
      json += "\"v\":"  + IntegerToString((long)rates[i].tick_volume);
      json += "}";
     }
   json += "]}";
   PostJSON("/bars", json);
  }

//+------------------------------------------------------------------+
void SendPositions()
  {
   string json = "{\"positions\":[";
   int total = PositionsTotal();
   bool first = true;
   for(int i = 0; i < total; i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(TrackMagic != 0 && PositionGetInteger(POSITION_MAGIC) != TrackMagic) continue;
      if(!first) json += ",";
      json += "{";
      json += "\"ticket\":"        + IntegerToString(ticket) + ",";
      json += "\"symbol\":\""      + PositionGetString(POSITION_SYMBOL) + "\",";
      json += "\"direction\":\""   + (PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY?"BUY":"SELL") + "\",";
      json += "\"open_price\":"    + DoubleToString(PositionGetDouble(POSITION_PRICE_OPEN),    5) + ",";
      json += "\"current_price\":" + DoubleToString(PositionGetDouble(POSITION_PRICE_CURRENT), 5) + ",";
      json += "\"profit\":"        + DoubleToString(PositionGetDouble(POSITION_PROFIT), 2) + ",";
      json += "\"volume\":"        + DoubleToString(PositionGetDouble(POSITION_VOLUME), 2) + ",";
      json += "\"sl\":"            + DoubleToString(PositionGetDouble(POSITION_SL), 5) + ",";
      json += "\"tp\":"            + DoubleToString(PositionGetDouble(POSITION_TP), 5) + ",";
      json += "\"time\":"          + IntegerToString((long)PositionGetInteger(POSITION_TIME));
      json += "}";
      first = false;
     }

   json += "],\"history\":[";

   int deals = HistoryDealsTotal();
   first = true;
   for(int i = deals - 1; i >= 0; i--)
     {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;
      if(TrackMagic != 0 && HistoryDealGetInteger(ticket, DEAL_MAGIC) != TrackMagic) continue;
      long dtype = HistoryDealGetInteger(ticket, DEAL_TYPE);
      if(dtype != DEAL_TYPE_BUY && dtype != DEAL_TYPE_SELL) continue;
      datetime deal_time = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);

      double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
      if(!first) json += ",";
      json += "{";
      json += "\"ticket\":"      + IntegerToString(ticket) + ",";
      json += "\"symbol\":\""    + HistoryDealGetString(ticket, DEAL_SYMBOL) + "\",";
      json += "\"direction\":\"" + (dtype==DEAL_TYPE_BUY?"BUY":"SELL") + "\",";
      json += "\"profit\":"      + DoubleToString(profit, 2) + ",";
      json += "\"volume\":"      + DoubleToString(HistoryDealGetDouble(ticket, DEAL_VOLUME), 2) + ",";
      json += "\"result\":\""    + (profit>=0?"WIN":"LOSS") + "\",";
      json += "\"time\":"        + IntegerToString((long)deal_time);
      json += "}";
      first = false;
     }

   json += "]}";
   PostJSON("/positions", json);
  }
//+------------------------------------------------------------------+
