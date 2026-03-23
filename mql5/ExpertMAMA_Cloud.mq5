//+------------------------------------------------------------------+
//|                                        ExpertMAMA_Cloud.mq5     |
//|                        Copyright 2000-2026, MetaQuotes Ltd.     |
//|  MT5 → Contabo VPS FastAPI bridge                               |
//+------------------------------------------------------------------+
#property copyright "Copyright 2000-2026, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.00"

#include <Expert\Expert.mqh>
#include <Expert\Signal\SignalMA.mqh>
#include <Expert\Trailing\TrailingMA.mqh>
#include <Expert\Money\MoneyFixedLot.mqh>

//--- Expert inputs
input string             Inp_Expert_Title        = "ExpertMAMA_Cloud";
int                      Expert_MagicNumber      = 12003;
bool                     Expert_EveryTick        = false;

//--- Signal inputs
input int                Inp_Signal_MA_Period    = 12;
input int                Inp_Signal_MA_Shift     = 6;
input ENUM_MA_METHOD     Inp_Signal_MA_Method    = MODE_SMA;
input ENUM_APPLIED_PRICE Inp_Signal_MA_Applied   = PRICE_CLOSE;

//--- SL / TP
input int                Inp_StopLoss            = 1000;
input int                Inp_TakeProfit          = 1500;

//--- Trailing
input int                Inp_Trailing_MA_Period  = 12;
input int                Inp_Trailing_MA_Shift   = 0;
input ENUM_MA_METHOD     Inp_Trailing_MA_Method  = MODE_SMA;
input ENUM_APPLIED_PRICE Inp_Trailing_MA_Applied = PRICE_CLOSE;

//--- Money
input double             Inp_Money_FixLot        = 0.1;

//--- VPS Ayarları
// !! VPS IP'nizi buraya yazın !!
input string             Inp_VPS_IP              = "123.456.789.0";
input int                Inp_VPS_Port            = 8765;

//--- Gönderme sıklığı
input int                Inp_TickInterval        = 3;   // kaç tick'te bir tick gönder
input int                Inp_BarInterval         = 1;   // kaç barda bir bar gönder (her bar)
input int                Inp_PosInterval         = 5;   // kaç tick'te bir pozisyon gönder

CExpert ExtExpert;
int     g_tick_count = 0;
int     g_pos_count  = 0;
datetime g_last_bar  = 0;
string  g_base_url;

//+------------------------------------------------------------------+
int OnInit(void)
  {
   g_base_url = "http://" + Inp_VPS_IP + ":" + IntegerToString(Inp_VPS_Port);

   if(!ExtExpert.Init(Symbol(), Period(), Expert_EveryTick, Expert_MagicNumber))
     { printf(__FUNCTION__+": error initializing expert"); ExtExpert.Deinit(); return(INIT_FAILED); }

   CSignalMA *signal = new CSignalMA;
   if(signal==NULL || !ExtExpert.InitSignal(signal))
     { printf(__FUNCTION__+": error signal"); ExtExpert.Deinit(); return(INIT_FAILED); }
   signal.PeriodMA(Inp_Signal_MA_Period);
   signal.Shift(Inp_Signal_MA_Shift);
   signal.Method(Inp_Signal_MA_Method);
   signal.Applied(Inp_Signal_MA_Applied);
   signal.StopLevel(Inp_StopLoss);
   signal.TakeLevel(Inp_TakeProfit);
   if(!signal.ValidationSettings())
     { printf(__FUNCTION__+": error signal validation"); ExtExpert.Deinit(); return(INIT_FAILED); }

   CTrailingMA *trailing = new CTrailingMA;
   if(trailing==NULL || !ExtExpert.InitTrailing(trailing))
     { printf(__FUNCTION__+": error trailing"); ExtExpert.Deinit(); return(INIT_FAILED); }
   trailing.Period(Inp_Trailing_MA_Period);
   trailing.Shift(Inp_Trailing_MA_Shift);
   trailing.Method(Inp_Trailing_MA_Method);
   trailing.Applied(Inp_Trailing_MA_Applied);
   if(!trailing.ValidationSettings())
     { printf(__FUNCTION__+": error trailing validation"); ExtExpert.Deinit(); return(INIT_FAILED); }

   CMoneyFixedLot *money = new CMoneyFixedLot;
   if(money==NULL || !ExtExpert.InitMoney(money))
     { printf(__FUNCTION__+": error money"); ExtExpert.Deinit(); return(INIT_FAILED); }
   money.Lots(Inp_Money_FixLot);
   if(!money.ValidationSettings())
     { printf(__FUNCTION__+": error money validation"); ExtExpert.Deinit(); return(INIT_FAILED); }

   if(!ExtExpert.ValidationSettings())
     { printf(__FUNCTION__+": error expert validation"); ExtExpert.Deinit(); return(INIT_FAILED); }
   if(!ExtExpert.InitIndicators())
     { printf(__FUNCTION__+": error indicators"); ExtExpert.Deinit(); return(INIT_FAILED); }

   // İlk bar verisini gönder
   SendBars(200);
   SendPositions();

   printf("ExpertMAMA_Cloud başladı → " + g_base_url);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason) { ExtExpert.Deinit(); }

void OnTick(void)
  {
   ExtExpert.OnTick();
   g_tick_count++;
   g_pos_count++;

   if(g_tick_count >= Inp_TickInterval)
     { SendTick(); g_tick_count = 0; }

   if(g_pos_count >= Inp_PosInterval)
     { SendPositions(); g_pos_count = 0; }

   // Yeni bar kapandı mı?
   datetime cur_bar = iTime(Symbol(), Period(), 0);
   if(cur_bar != g_last_bar && g_last_bar != 0)
     { SendBars(Inp_BarInterval); }
   g_last_bar = cur_bar;
  }

void OnTrade(void)  { ExtExpert.OnTrade(); SendPositions(); }
void OnTimer(void)  { ExtExpert.OnTimer(); }

//+------------------------------------------------------------------+
//| HTTP POST yardımcısı                                             |
//+------------------------------------------------------------------+
bool PostJSON(string endpoint, string json_body)
  {
   string url     = g_base_url + endpoint;
   string headers = "Content-Type: application/json\r\n";
   char   post_data[];
   char   result[];
   string result_headers;

   // latin-1 uyumlu encoding
   int len = StringToCharArray(json_body, post_data, 0, WHOLE_ARRAY, CP_ACP);
   if(len > 0 && post_data[len-1] == 0) ArrayResize(post_data, len-1);

   int res = WebRequest("POST", url, headers, 5000, post_data, result, result_headers);
   if(res == -1)
     {
      int err = GetLastError();
      if(err == 4014)
        printf("WebRequest hata: URL whitelist'e ekleyin → " + url);
      return(false);
     }
   return(true);
  }

//+------------------------------------------------------------------+
//| Tick verisi gönder                                               |
//+------------------------------------------------------------------+
void SendTick()
  {
   double bid      = SymbolInfoDouble(Symbol(), SYMBOL_BID);
   double ask      = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
   double point    = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   double spread   = (ask - bid) / point;
   double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
   double margin   = AccountInfoDouble(ACCOUNT_MARGIN);
   double free_mrg = AccountInfoDouble(ACCOUNT_FREEMARGIN);
   string currency = AccountInfoString(ACCOUNT_CURRENCY);

   string json = "{";
   json += "\"symbol\":\"" + Symbol() + "\",";
   json += "\"bid\":"      + DoubleToString(bid,  5) + ",";
   json += "\"ask\":"      + DoubleToString(ask,  5) + ",";
   json += "\"spread\":"   + DoubleToString(spread,1) + ",";
   json += "\"balance\":"  + DoubleToString(balance, 2) + ",";
   json += "\"equity\":"   + DoubleToString(equity,  2) + ",";
   json += "\"margin\":"   + DoubleToString(margin,  2) + ",";
   json += "\"free_margin\":" + DoubleToString(free_mrg, 2) + ",";
   json += "\"currency\":\"" + currency + "\",";
   json += "\"time\":"     + IntegerToString((long)TimeCurrent());
   json += "}";

   PostJSON("/tick", json);
  }

//+------------------------------------------------------------------+
//| Bar verisi gönder                                                |
//+------------------------------------------------------------------+
void SendBars(int count)
  {
   if(count < 1) count = 1;
   if(count > 500) count = 500;

   MqlRates rates[];
   int copied = CopyRates(Symbol(), Period(), 0, count, rates);
   if(copied <= 0) return;

   string json = "{\"symbol\":\"" + Symbol() + "\",\"bars\":[";
   for(int i = 0; i < copied; i++)
     {
      if(i > 0) json += ",";
      json += "{";
      json += "\"t\":"  + IntegerToString((long)rates[i].time)         + ",";
      json += "\"o\":"  + DoubleToString(rates[i].open,   5)           + ",";
      json += "\"h\":"  + DoubleToString(rates[i].high,   5)           + ",";
      json += "\"l\":"  + DoubleToString(rates[i].low,    5)           + ",";
      json += "\"c\":"  + DoubleToString(rates[i].close,  5)           + ",";
      json += "\"v\":"  + IntegerToString((long)rates[i].tick_volume);
      json += "}";
     }
   json += "]}";

   PostJSON("/bars", json);
  }

//+------------------------------------------------------------------+
//| Pozisyon ve işlem geçmişi gönder                                 |
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
      if(PositionGetInteger(POSITION_MAGIC) != Expert_MagicNumber) continue;

      if(!first) json += ",";
      json += "{";
      json += "\"ticket\":"       + IntegerToString(ticket)                                          + ",";
      json += "\"symbol\":\""     + PositionGetString(POSITION_SYMBOL)                               + "\",";
      json += "\"direction\":\""  + (PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY?"BUY":"SELL") + "\",";
      json += "\"open_price\":"   + DoubleToString(PositionGetDouble(POSITION_PRICE_OPEN), 5)        + ",";
      json += "\"current_price\":"+ DoubleToString(PositionGetDouble(POSITION_PRICE_CURRENT), 5)     + ",";
      json += "\"profit\":"       + DoubleToString(PositionGetDouble(POSITION_PROFIT), 2)            + ",";
      json += "\"volume\":"       + DoubleToString(PositionGetDouble(POSITION_VOLUME), 2)            + ",";
      json += "\"sl\":"           + DoubleToString(PositionGetDouble(POSITION_SL), 5)               + ",";
      json += "\"tp\":"           + DoubleToString(PositionGetDouble(POSITION_TP), 5)               + ",";
      json += "\"time\":"         + IntegerToString((long)PositionGetInteger(POSITION_TIME));
      json += "}";
      first = false;
     }

   json += "],\"history\":[";

   // Son 50 işlem
   int deals = HistoryDealsTotal();
   int added = 0;
   first = true;
   for(int i = deals-1; i >= 0 && added < 50; i--)
     {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != Expert_MagicNumber) continue;
      long dtype = HistoryDealGetInteger(ticket, DEAL_TYPE);
      if(dtype != DEAL_TYPE_BUY && dtype != DEAL_TYPE_SELL) continue;

      double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
      if(!first) json += ",";
      json += "{";
      json += "\"ticket\":"      + IntegerToString(ticket)                                  + ",";
      json += "\"symbol\":\""    + HistoryDealGetString(ticket, DEAL_SYMBOL)                + "\",";
      json += "\"direction\":\"" + (dtype==DEAL_TYPE_BUY?"BUY":"SELL")                     + "\",";
      json += "\"profit\":"      + DoubleToString(profit, 2)                               + ",";
      json += "\"volume\":"      + DoubleToString(HistoryDealGetDouble(ticket,DEAL_VOLUME),2)+ ",";
      json += "\"result\":\""    + (profit>=0?"WIN":"LOSS")                                + "\",";
      json += "\"time\":"        + IntegerToString((long)HistoryDealGetInteger(ticket,DEAL_TIME));
      json += "}";
      first = false;
      added++;
     }

   json += "]}";
   PostJSON("/positions", json);
  }
//+------------------------------------------------------------------+
