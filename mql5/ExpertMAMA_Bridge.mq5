//+------------------------------------------------------------------+
//|                                        ExpertMAMA_Bridge.mq5    |
//|  VERİ KÖPRÜSÜ + OTOMATİK İŞLEM MOTORU                         |
//+------------------------------------------------------------------+
#property copyright "Copyright 2000-2026 MetaQuotes Ltd."
#property version   "3.00"
#property description "MT5 ↔ VPS köprüsü + otomatik işlem motoru"

ENUM_TIMEFRAMES StrToTF(string tf); // forward declaration

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

CTrade         trade;
CPositionInfo  posInfo;

string VPS_URL      = "http://94.250.203.232:8765";
input int    TickEvery   = 10;
input int    PosEvery    = 30;
input int    TrackMagic  = 0;
input int    StratEvery  = 30;  // kaç tick'te bir strateji güncelle

// Sembol listesi
string SYMBOLS[] = {
   "EURUSD","GBPUSD","AUDUSD","USDJPY","EURJPY","USDCAD","EURGBP"
};
int SYM_COUNT = 7;

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
   double tp_pip;
   double atr_mult;
   bool   active;
   int    handle_fast;  // MA handle — önceden açılır
   int    handle_slow;
   int    handle_atr;
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
   // Strateji motoru — her zaman çalışır (oto mod VPS'ten okunur)
   RunStrategies();
  }

void OnTimer(void)
  {
   static int send_sym=0, send_tf=0;
   static bool init_done=false;

   if(!init_done)
     {
      // Her timer'da bir sonraki sembol/TF gönder
      if(send_sym<SYM_COUNT)
        {
         if(send_sym==0&&send_tf==0) printf("İlk bar verisi gönderiliyor...");
         SendBars(SYMBOLS[send_sym],TFS[send_tf],TF_NAMES[send_tf],3000);
         send_tf++;
         if(send_tf>=TF_COUNT){send_tf=0;send_sym++;}
        }
      else
        {
         SendPositions();
         FetchStrategies();
         g_bars_sent=true;
         init_done=true;
         printf("İlk veri tamamlandı.");
        }
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
   int res=WebRequest("POST",VPS_URL+endpoint,headers,15000,post,result,rh);
   if(res==-1) printf("WebRequest HATA: "+IntegerToString(GetLastError())+" endpoint="+endpoint+" body_len="+IntegerToString(ArraySize(post)));
   else if(res!=200) printf("WebRequest HTTP "+IntegerToString(res)+" endpoint="+endpoint);
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
   json+="\"free_margin\":"+DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN_FREE),2)+",";
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
           +"\"comment\":\""+PositionGetString(POSITION_COMMENT)+"\","
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
           +"\"comment\":\""+HistoryDealGetString(t,DEAL_COMMENT)+"\","
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
   g_auto_mode = (StringFind(resp,"\"auto_mode\":true")>=0 || StringFind(resp,"\"auto_mode\": true")>=0);

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
      s.tp_pip   = ExtractNum(obj,"\"tp_pip\":");
      s.atr_mult = ExtractNum(obj,"\"atr_mult\":");
      s.active   = (StringFind(obj,"\"active\":true")>=0);

      if(s.symbol!=""&&s.active)
        {
         ENUM_TIMEFRAMES stf=StrToTF(s.tf);
         ENUM_MA_METHOD method=MODE_EMA;
         if(s.ma_type=="SMA") method=MODE_SMA;
         else if(s.ma_type=="WMA") method=MODE_LWMA;
         s.handle_fast = iMA(s.symbol,stf,s.fast,0,method,PRICE_CLOSE);
         s.handle_slow = iMA(s.symbol,stf,s.slow,0,method,PRICE_CLOSE);
         s.handle_atr  = iATR(s.symbol,stf,14);
         g_strategies[g_strat_count]=s;
         // İlk çalışmada yanlış işlem açmasın — mevcut bar zamanını kaydet
         g_strat_last_bar[g_strat_count]=iTime(s.symbol,StrToTF(s.tf),0);
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
int StratMagic(string id)
  {
   int hash=12100;
   for(int i=0;i<StringLen(id);i++)
      hash=(hash*31+(int)StringGetCharacter(id,i))&0x7FFFFFFF;
   return hash;
  }

//+------------------------------------------------------------------+
//| Bu stratejiye ait açık pozisyon var mı?                         |
//+------------------------------------------------------------------+
bool HasPosition(string sym, int magic, long &pos_type, ulong &pos_ticket)
  {
   pos_type=0; pos_ticket=0;
   for(int i=0;i<PositionsTotal();i++)
     {
      ulong t=PositionGetTicket(i);
      if(t==0) continue;
      if(PositionGetString(POSITION_SYMBOL)==sym&&(long)PositionGetInteger(POSITION_MAGIC)==magic)
        {
         pos_type=(long)PositionGetInteger(POSITION_TYPE);
         pos_ticket=t;
         return true;
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
//| ATR trailing SL güncelle                                        |
//+------------------------------------------------------------------+
void UpdateTrailingSL(string sym, ulong ticket, int atr_handle, double atr_mult)
  {
   if(!PositionSelectByTicket(ticket)) return;
   long  pos_type   = PositionGetInteger(POSITION_TYPE);
   double cur_price = PositionGetDouble(POSITION_PRICE_CURRENT);
   double cur_sl    = PositionGetDouble(POSITION_SL);
   double atr_buf[1];
   if(CopyBuffer(atr_handle,0,1,1,atr_buf)<=0) return;
   double trail_dist = atr_buf[0] * atr_mult;
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
   if(!g_auto_mode || g_strat_count==0) return;
   for(int i=0;i<g_strat_count;i++)
     {
      string sym     = g_strategies[i].symbol;
      string tf_str  = g_strategies[i].tf;
      int    fast    = g_strategies[i].fast;
      int    slow    = g_strategies[i].slow;
      string ma_type = g_strategies[i].ma_type;
      double lot     = g_strategies[i].lot;
      double atr_mult= g_strategies[i].atr_mult;
      string strat_id= g_strategies[i].id;

      ENUM_TIMEFRAMES tf=StrToTF(tf_str);
      int magic=StratMagic(strat_id);

      // Trailing SL her tick güncelle
      long pos_type=0; ulong pos_ticket=0;
      bool has_pos=HasPosition(sym,magic,pos_type,pos_ticket);
      if(has_pos) UpdateTrailingSL(sym,pos_ticket,g_strategies[i].handle_atr,atr_mult);

      double mF_buf[2], mS_buf[2];
      if(CopyBuffer(g_strategies[i].handle_fast,0,0,2,mF_buf)<=0) continue;
      if(CopyBuffer(g_strategies[i].handle_slow,0,0,2,mS_buf)<=0) continue;
      double mF_cur=mF_buf[1], mF_prev=mF_buf[0];
      double mS_cur=mS_buf[1], mS_prev=mS_buf[0];

      // Aynı barda tekrar açma (stop sonrası dahil)
      datetime cur_bar=iTime(sym,tf,0);
      if(cur_bar==g_strat_last_bar[i]) continue;

      // Kesişim: önceki barda altta/üstte, şimdi üstte/altta
      bool crossUp = mF_cur>mS_cur && mF_prev<=mS_prev;
      bool crossDn = mF_cur<mS_cur && mF_prev>=mS_prev;

      if(!crossUp&&!crossDn) continue;

      g_strat_last_bar[i]=cur_bar;

      // Açık pozisyon varsa aynı yönde tekrar açma
      if(crossUp && has_pos && pos_type==POSITION_TYPE_BUY) continue;
      if(crossDn && has_pos && pos_type==POSITION_TYPE_SELL) continue;
      double point   = SymbolInfoDouble(sym,SYMBOL_POINT);
      double atr_buf[1];
      double atr=0;
      if(CopyBuffer(g_strategies[i].handle_atr,0,1,1,atr_buf)>0) atr=atr_buf[0];
      double sl_dist  = (atr>0) ? atr*atr_mult : g_strategies[i].sl_pip*10*point;
      double sl_pip   = g_strategies[i].sl_pip;
      double tp_pip   = g_strategies[i].tp_pip;

      if(crossUp)
        {
         if(has_pos&&pos_type==POSITION_TYPE_SELL)
            trade.PositionClose(pos_ticket);
         double ask = SymbolInfoDouble(sym,SYMBOL_ASK);
         double sl  = sl_pip>0 ? ask - sl_pip*10*point : ask - sl_dist;
         double tp  = tp_pip>0 ? ask + tp_pip*10*point : 0;
         trade.SetExpertMagicNumber(magic);
         if(trade.Buy(lot,sym,ask,sl,tp,strat_id))
            printf("BUY açıldı: "+sym+" "+strat_id+" SL="+DoubleToString(sl,5)+" TP="+DoubleToString(tp,5));
        }
      else if(crossDn)
        {
         if(has_pos&&pos_type==POSITION_TYPE_BUY)
            trade.PositionClose(pos_ticket);
         double bid = SymbolInfoDouble(sym,SYMBOL_BID);
         double sl  = sl_pip>0 ? bid + sl_pip*10*point : bid + sl_dist;
         double tp  = tp_pip>0 ? bid - tp_pip*10*point : 0;
         trade.SetExpertMagicNumber(magic);
         if(trade.Sell(lot,sym,bid,sl,tp,strat_id))
            printf("SELL açıldı: "+sym+" "+strat_id+" SL="+DoubleToString(sl,5)+" TP="+DoubleToString(tp,5));
        }
     }
  }
//+------------------------------------------------------------------+
