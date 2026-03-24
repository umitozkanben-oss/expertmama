//+------------------------------------------------------------------+
//|                                        ExpertMAMA_Bridge.mq5    |
//|  VERİ KÖPRÜSÜ + OTOMATİK İŞLEM MOTORU                         |
//+------------------------------------------------------------------+
#property copyright "Copyright 2000-2026, MetaQuotes Ltd."
#property version   "3.00"
#property description "MT5 ↔ VPS köprüsü + otomatik işlem motoru"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

CTrade         trade;
CPositionInfo  posInfo;

string VPS_URL      = "http://94.250.203.232:8765";
input int    TickEvery   = 3;
input int    PosEvery    = 10;
input int    TrackMagic  = 0;
input int    StratEvery  = 30;  // kaç tick'te bir strateji güncelle

// Sembol listesi
string SYMBOLS[] = {
   "EURUSD","GBPUSD","AUDUSD","AUDCAD","USDJPY","EURJPY",
   "USDCHF","USDCAD","XAUUSD","BTCUSD","US100","NZDUSD"
};
int SYM_COUNT = 12;

ENUM_TIMEFRAMES TFS[]    = {PERIOD_M5, PERIOD_M15, PERIOD_H1, PERIOD_H4};
string          TF_NAMES[] = {"M5","M15","H1","H4"};
int TF_COUNT = 4;

int      g_tick=0, g_pos=0, g_strat=0;
bool     g_bars_sent=false;
datetime g_last_bars[12][4];

// Strateji yapısı
struct Strategy {
   string id;
   string symbol;
   string tf;
   int    fast;
   int    slow;
   string ma_type;
   double lot;
   double sl_pip;
   double atr_mult;
   bool   active;
};

Strategy g_strategies[50];
int      g_strat_count = 0;
bool     g_auto_mode   = false;

// Son işlenen bar zamanları — her strateji için
datetime g_strat_last_bar[50];

//+------------------------------------------------------------------+
int OnInit(void)
  {
   trade.SetExpertMagicNumber(12003);
   trade.SetDeviationInPoints(10);
   for(int i=0;i<12;i++) for(int j=0;j<4;j++) g_last_bars[i][j]=0;
   for(int i=0;i<50;i++) g_strat_last_bar[i]=0;
   EventSetTimer(3);
   printf("ExpertMAMA Bridge v3 başladı → "+VPS_URL);
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason) { EventKillTimer(); }

void OnTick(void)
  {
   g_tick++; g_pos++; g_strat++;

   if(g_tick>=TickEvery)   { for(int i=0;i<SYM_COUNT;i++) SendTick(SYMBOLS[i]); g_tick=0; }
   if(g_pos>=PosEvery)     { SendPositions(); g_pos=0; }
   if(g_strat>=StratEvery) { FetchStrategies(); g_strat=0; }

   // Yeni bar kontrolü
   for(int i=0;i<SYM_COUNT;i++)
      for(int j=0;j<TF_COUNT;j++)
        {
         datetime b=iTime(SYMBOLS[i],TFS[j],0);
         if(g_last_bars[i][j]!=0&&b!=g_last_bars[i][j]) SendBars(SYMBOLS[i],TFS[j],TF_NAMES[j],3);
         g_last_bars[i][j]=b;
        }

   // Otomatik işlem motoru
   if(g_auto_mode) RunStrategies();
  }

void OnTimer(void)
  {
   if(!g_bars_sent)
     {
      printf("İlk bar verisi gönderiliyor...");
      for(int i=0;i<SYM_COUNT;i++)
         for(int j=0;j<TF_COUNT;j++)
            SendBars(SYMBOLS[i],TFS[j],TF_NAMES[j],1000);
      SendPositions();
      FetchStrategies();
      g_bars_sent=true;
      printf("İlk veri tamamlandı.");
     }
  }

void OnTrade(void) { SendPositions(); }

//+------------------------------------------------------------------+
//| HTTP yardımcıları                                                |
//+------------------------------------------------------------------+
bool PostJSON(string endpoint, string body)
  {
   string headers="Content-Type: application/json\r\n";
   char post[],result[]; string rh;
   int len=StringToCharArray(body,post,0,WHOLE_ARRAY,CP_ACP);
   if(len>0&&post[len-1]==0) ArrayResize(post,len-1);
   int res=WebRequest("POST",VPS_URL+endpoint,headers,5000,post,result,rh);
   if(res==-1&&GetLastError()==4014) printf("Whitelist'e ekleyin: "+VPS_URL);
   return res!=-1;
  }

string GetJSON(string endpoint)
  {
   string headers="";
   char post[],result[]; string rh;
   int res=WebRequest("GET",VPS_URL+endpoint,headers,5000,post,result,rh);
   if(res==-1) return "";
   return CharArrayToString(result,0,WHOLE_ARRAY,CP_ACP);
  }

//+------------------------------------------------------------------+
//| Tick gönder (tick_value dahil)                                   |
//+------------------------------------------------------------------+
void SendTick(string sym)
  {
   double bid=SymbolInfoDouble(sym,SYMBOL_BID);
   double ask=SymbolInfoDouble(sym,SYMBOL_ASK);
   double pt =SymbolInfoDouble(sym,SYMBOL_POINT);
   double tv =SymbolInfoDouble(sym,SYMBOL_TRADE_TICK_VALUE); // pip değeri
   if(bid==0) return;
   string json="{";
   json+="\"symbol\":\""+sym+"\",";
   json+="\"bid\":"+DoubleToString(bid,5)+",";
   json+="\"ask\":"+DoubleToString(ask,5)+",";
   json+="\"spread\":"+DoubleToString((ask-bid)/pt,1)+",";
   json+="\"tick_value\":"+DoubleToString(tv,5)+",";
   json+="\"balance\":"+DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE),2)+",";
   json+="\"equity\":"+DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY),2)+",";
   json+="\"margin\":"+DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN),2)+",";
   json+="\"free_margin\":"+DoubleToString(AccountInfoDouble(ACCOUNT_FREEMARGIN),2)+",";
   json+="\"currency\":\""+AccountInfoString(ACCOUNT_CURRENCY)+"\",";
   json+="\"time\":"+IntegerToString((long)TimeCurrent());
   json+="}";
   PostJSON("/tick",json);
  }

//+------------------------------------------------------------------+
//| Bar gönder                                                       |
//+------------------------------------------------------------------+
void SendBars(string sym, ENUM_TIMEFRAMES tf, string tf_str, int count)
  {
   MqlRates rates[];
   int copied=CopyRates(sym,tf,0,count,rates);
   if(copied<=0) return;
   string json="{\"symbol\":\""+sym+"\",\"tf\":\""+tf_str+"\",\"bars\":[";
   for(int i=0;i<copied;i++)
     {
      if(i>0) json+=",";
      json+="{\"t\":"+IntegerToString((long)rates[i].time)+","
           +"\"o\":"+DoubleToString(rates[i].open,5)+","
           +"\"h\":"+DoubleToString(rates[i].high,5)+","
           +"\"l\":"+DoubleToString(rates[i].low,5)+","
           +"\"c\":"+DoubleToString(rates[i].close,5)+","
           +"\"v\":"+IntegerToString((long)rates[i].tick_volume)+"}";
     }
   json+="]}";
   PostJSON("/bars",json);
  }

//+------------------------------------------------------------------+
//| Pozisyon gönder                                                  |
//+------------------------------------------------------------------+
void SendPositions()
  {
   HistorySelect(0,TimeCurrent());
   string json="{\"positions\":[";
   bool first=true;
   for(int i=0;i<PositionsTotal();i++)
     {
      ulong t=PositionGetTicket(i);
      if(t==0) continue;
      if(TrackMagic!=0&&PositionGetInteger(POSITION_MAGIC)!=TrackMagic) continue;
      if(!first) json+=","; first=false;
      json+="{\"ticket\":"+IntegerToString(t)+","
           +"\"symbol\":\""+PositionGetString(POSITION_SYMBOL)+"\","
           +"\"direction\":\""+(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY?"BUY":"SELL")+"\","
           +"\"open_price\":"+DoubleToString(PositionGetDouble(POSITION_PRICE_OPEN),5)+","
           +"\"current_price\":"+DoubleToString(PositionGetDouble(POSITION_PRICE_CURRENT),5)+","
           +"\"profit\":"+DoubleToString(PositionGetDouble(POSITION_PROFIT),2)+","
           +"\"volume\":"+DoubleToString(PositionGetDouble(POSITION_VOLUME),2)+","
           +"\"sl\":"+DoubleToString(PositionGetDouble(POSITION_SL),5)+","
           +"\"tp\":"+DoubleToString(PositionGetDouble(POSITION_TP),5)+","
           +"\"time\":"+IntegerToString((long)PositionGetInteger(POSITION_TIME))+"}";
     }
   json+="],\"history\":[";
   first=true;
   int deals=HistoryDealsTotal();
   for(int i=deals-1;i>=0;i--)
     {
      ulong t=HistoryDealGetTicket(i);
      if(t==0) continue;
      if(TrackMagic!=0&&HistoryDealGetInteger(t,DEAL_MAGIC)!=TrackMagic) continue;
      long dtype=HistoryDealGetInteger(t,DEAL_TYPE);
      if(dtype!=DEAL_TYPE_BUY&&dtype!=DEAL_TYPE_SELL) continue;
      double profit=HistoryDealGetDouble(t,DEAL_PROFIT);
      if(!first) json+=","; first=false;
      json+="{\"ticket\":"+IntegerToString(t)+","
           +"\"symbol\":\""+HistoryDealGetString(t,DEAL_SYMBOL)+"\","
           +"\"direction\":\""+(dtype==DEAL_TYPE_BUY?"BUY":"SELL")+"\","
           +"\"profit\":"+DoubleToString(profit,2)+","
           +"\"volume\":"+DoubleToString(HistoryDealGetDouble(t,DEAL_VOLUME),2)+","
           +"\"result\":\""+(profit>=0?"WIN":"LOSS")+"\","
           +"\"time\":"+IntegerToString((long)HistoryDealGetInteger(t,DEAL_TIME))+"}";
     }
   json+="]}";
   PostJSON("/positions",json);
  }

//+------------------------------------------------------------------+
//| VPS'ten stratejileri çek                                        |
//+------------------------------------------------------------------+
void FetchStrategies()
  {
   string resp=GetJSON("/strategies");
   if(resp=="") return;

   // Basit JSON parser — "enabled": true/false
   g_auto_mode = (StringFind(resp,"\"enabled\": true")>=0 || StringFind(resp,"\"enabled\":true")>=0);

   g_strat_count=0;
   int pos=0;
   while(g_strat_count<50)
     {
      int start=StringFind(resp,"{\"id\":",pos);
      if(start<0) break;
      int end=StringFind(resp,"}",start);
      if(end<0) break;
      string obj=StringSubstr(resp,start,end-start+1);

      Strategy s;
      s.id       = ExtractStr(obj,"\"id\":");
      s.symbol   = ExtractStr(obj,"\"symbol\":");
      s.tf       = ExtractStr(obj,"\"tf\":");
      s.ma_type  = ExtractStr(obj,"\"ma_type\":");
      s.fast     = (int)ExtractNum(obj,"\"fast\":");
      s.slow     = (int)ExtractNum(obj,"\"slow\":");
      s.lot      = ExtractNum(obj,"\"lot\":");
      s.sl_pip   = ExtractNum(obj,"\"sl_pip\":");
      s.atr_mult = ExtractNum(obj,"\"atr_mult\":");
      s.active   = (StringFind(obj,"\"active\":true")>=0);

      if(s.symbol!=""&&s.active)
        {
         g_strategies[g_strat_count]=s;
         g_strat_count++;
        }
      pos=end+1;
     }
  }

string ExtractStr(string json, string key)
  {
   int p=StringFind(json,key);
   if(p<0) return "";
   p+=StringLen(key);
   while(p<StringLen(json)&&(StringGetCharacter(json,p)==' '||StringGetCharacter(json,p)=='"')) p++;
   string result="";
   while(p<StringLen(json))
     {
      ushort c=StringGetCharacter(json,p);
      if(c=='"'||c==','||c=='}'||c==']') break;
      result+=ShortToString(c); p++;
     }
   return result;
  }

double ExtractNum(string json, string key)
  {
   int p=StringFind(json,key);
   if(p<0) return 0;
   p+=StringLen(key);
   while(p<StringLen(json)&&StringGetCharacter(json,p)==' ') p++;
   string num="";
   while(p<StringLen(json))
     {
      ushort c=StringGetCharacter(json,p);
      if(c==','||c=='}'||c==']'||c==' ') break;
      num+=ShortToString(c); p++;
     }
   return StringToDouble(num);
  }

//+------------------------------------------------------------------+
//| MA hesapla                                                       |
//+------------------------------------------------------------------+
double GetMA(string sym, ENUM_TIMEFRAMES tf, int period, string ma_type, int shift)
  {
   ENUM_MA_METHOD method=MODE_EMA;
   if(ma_type=="SMA") method=MODE_SMA;
   else if(ma_type=="WMA") method=MODE_LWMA;
   int handle=iMA(sym,tf,period,0,method,PRICE_CLOSE);
   if(handle==INVALID_HANDLE) return 0;
   double buf[1];
   if(CopyBuffer(handle,0,shift,1,buf)<=0) { IndicatorRelease(handle); return 0; }
   IndicatorRelease(handle);
   return buf[0];
  }

//+------------------------------------------------------------------+
//| ATR hesapla                                                      |
//+------------------------------------------------------------------+
double GetATR(string sym, ENUM_TIMEFRAMES tf, int period, int shift)
  {
   int handle=iATR(sym,tf,period);
   if(handle==INVALID_HANDLE) return 0;
   double buf[1];
   if(CopyBuffer(handle,0,shift,1,buf)<=0) { IndicatorRelease(handle); return 0; }
   IndicatorRelease(handle);
   return buf[0];
  }

//+------------------------------------------------------------------+
//| TF string → ENUM                                                 |
//+------------------------------------------------------------------+
ENUM_TIMEFRAMES StrToTF(string tf)
  {
   if(tf=="M5")  return PERIOD_M5;
   if(tf=="M15") return PERIOD_M15;
   if(tf=="H1")  return PERIOD_H1;
   if(tf=="H4")  return PERIOD_H4;
   return PERIOD_M15;
  }

//+------------------------------------------------------------------+
//| Strateji için magic number                                       |
//+------------------------------------------------------------------+
int StratMagic(int idx) { return 12100 + idx; }

//+------------------------------------------------------------------+
//| Bu stratejiye ait açık pozisyon var mı?                         |
//+------------------------------------------------------------------+
bool HasPosition(string sym, int magic, long &pos_type, ulong &pos_ticket)
  {
   for(int i=0;i<PositionsTotal();i++)
     {
      ulong t=PositionGetTicket(i);
      if(t==0) continue;
      if(PositionGetString(POSITION_SYMBOL)==sym&&PositionGetInteger(POSITION_MAGIC)==magic)
        {
         pos_type=PositionGetInteger(POSITION_TYPE);
         pos_ticket=t;
         return true;
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
//| ATR trailing SL güncelle                                        |
//+------------------------------------------------------------------+
void UpdateTrailingSL(string sym, ulong ticket, ENUM_TIMEFRAMES tf, double atr_mult)
  {
   if(!PositionSelectByTicket(ticket)) return;
   long  pos_type  = PositionGetInteger(POSITION_TYPE);
   double cur_price = PositionGetDouble(POSITION_PRICE_CURRENT);
   double cur_sl    = PositionGetDouble(POSITION_SL);
   double atr       = GetATR(sym,tf,14,0);
   if(atr<=0) return;
   double trail_dist = atr * atr_mult;
   double new_sl;
   if(pos_type==POSITION_TYPE_BUY)
     {
      new_sl = cur_price - trail_dist;
      if(new_sl > cur_sl + SymbolInfoDouble(sym,SYMBOL_POINT))
         trade.PositionModify(ticket,new_sl,PositionGetDouble(POSITION_TP));
     }
   else
     {
      new_sl = cur_price + trail_dist;
      if(cur_sl==0 || new_sl < cur_sl - SymbolInfoDouble(sym,SYMBOL_POINT))
         trade.PositionModify(ticket,new_sl,PositionGetDouble(POSITION_TP));
     }
  }

//+------------------------------------------------------------------+
//| Strateji motorunu çalıştır                                      |
//+------------------------------------------------------------------+
void RunStrategies()
  {
   for(int i=0;i<g_strat_count;i++)
     {
      Strategy &s=g_strategies[i];
      ENUM_TIMEFRAMES tf=StrToTF(s.tf);
      int magic=StratMagic(i);

      // Sadece yeni barda işlem sinyali kontrol et
      datetime cur_bar=iTime(s.symbol,tf,0);
      if(cur_bar==g_strat_last_bar[i]) 
        {
         // Aynı bar — sadece trailing güncelle
         long pos_type; ulong pos_ticket;
         if(HasPosition(s.symbol,magic,pos_type,pos_ticket))
            UpdateTrailingSL(s.symbol,pos_ticket,tf,s.atr_mult);
         continue;
        }
      g_strat_last_bar[i]=cur_bar;

      // MA değerleri: shift=1 (kapanan bar), shift=2 (önceki bar)
      double mF_cur  = GetMA(s.symbol,tf,s.fast,s.ma_type,1);
      double mS_cur  = GetMA(s.symbol,tf,s.slow,s.ma_type,1);
      double mF_prev = GetMA(s.symbol,tf,s.fast,s.ma_type,2);
      double mS_prev = GetMA(s.symbol,tf,s.slow,s.ma_type,2);

      if(mF_cur==0||mS_cur==0||mF_prev==0||mS_prev==0) continue;

      bool crossUp = mF_cur>mS_cur && mF_prev<=mS_prev;
      bool crossDn = mF_cur<mS_cur && mF_prev>=mS_prev;

      if(!crossUp&&!crossDn) continue; // Kesişim yok

      // Mevcut pozisyon var mı?
      long  pos_type=0; ulong pos_ticket=0;
      bool  has_pos=HasPosition(s.symbol,magic,pos_type,pos_ticket);

      double point = SymbolInfoDouble(s.symbol,SYMBOL_POINT);
      double atr   = GetATR(s.symbol,tf,14,1);
      double sl_dist = (atr>0) ? atr*s.atr_mult : s.sl_pip*10*point;

      if(crossUp)
        {
         // Önce SELL varsa kapat
         if(has_pos&&pos_type==POSITION_TYPE_SELL)
            trade.PositionClose(pos_ticket);
         // BUY aç
         double ask = SymbolInfoDouble(s.symbol,SYMBOL_ASK);
         double sl  = ask - sl_dist;
         trade.SetExpertMagicNumber(magic);
         if(trade.Buy(s.lot,s.symbol,ask,sl,0,"ExpertMAMA_"+s.id))
            printf("BUY açıldı: "+s.symbol+" "+s.id+" SL="+DoubleToString(sl,5));
        }
      else if(crossDn)
        {
         // Önce BUY varsa kapat
         if(has_pos&&pos_type==POSITION_TYPE_BUY)
            trade.PositionClose(pos_ticket);
         // SELL aç
         double bid = SymbolInfoDouble(s.symbol,SYMBOL_BID);
         double sl  = bid + sl_dist;
         trade.SetExpertMagicNumber(magic);
         if(trade.Sell(s.lot,s.symbol,bid,sl,0,"ExpertMAMA_"+s.id))
            printf("SELL açıldı: "+s.symbol+" "+s.id+" SL="+DoubleToString(sl,5));
        }
     }
  }
//+------------------------------------------------------------------+
