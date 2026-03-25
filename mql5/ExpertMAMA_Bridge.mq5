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

input string Inp_VPS_URL    = "http://94.250.203.232:8765"; // VPS API Adresi
input int    TickEvery      = 30;
input int    PosEvery       = 30;
input int    TrackMagic     = 0;
input int    StratEvery     = 30;  // kaç tick'te bir strateji güncelle

string VPS_URL = "";

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

// Risk yönetimi
bool     g_risk_enabled       = false;
double   g_daily_loss_limit   = 100.0;
int      g_max_open_positions = 10;
double   g_max_lot_per_trade  = 1.0;
double   g_day_start_balance  = 0.0;
datetime g_day_date           = 0;

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
   int    handle_fast;
   int    handle_slow;
   int    handle_atr;
   // Limit emir sistemi
   bool   use_limit_entry;  // true = kesişim öncesi limit emir kullan
   double proximity_pct;    // MA arası mesafenin yüzde kaçı kaldığında emir koy (örn 0.10)
   ulong  limit_ticket;     // Bekleyen limit emrin ticket (0 = yok)
   datetime limit_placed_bar; // Limit emrin konulduğu bar zamanı (expiry için)
};

Strategy g_strategies[50];
int      g_strat_count = 0;
bool     g_auto_mode   = false;

// Son işlenen bar zamanları — her strateji için
datetime g_strat_last_bar[50];

// ── SCALP STRATEJİ YAPISI ──
struct ScalpStrategy {
   string   id;
   string   symbol;
   string   tf;
   double   lot;
   double   engulf_pct;
   double   min_engulf_pip;
   double   pullback_pct;
   int      pullback_bars;
   double   tp_pip;
   double   tp_pct;
   double   sl_pip;
   bool     use_ma_filter;
   int      ma_fast;
   int      ma_slow;
   string   ma_type;
   double   max_spread_pip;
   bool     active;
   int      handle_fast;
   int      handle_slow;
   bool     engulf_detected;
   int      engulf_dir;
   double   engulf_high;
   double   engulf_low;
   double   engulf_open;
   double   engulf_close;
   int      pullback_count;
   datetime engulf_bar;
};

ScalpStrategy g_scalps[50];
int           g_scalp_count = 0;



//+------------------------------------------------------------------+
int OnInit(void)
  {
   VPS_URL = Inp_VPS_URL;
   // Trailing slash temizle
   while(StringLen(VPS_URL)>0 && StringGetCharacter(VPS_URL,StringLen(VPS_URL)-1)=='/')
      VPS_URL = StringSubstr(VPS_URL,0,StringLen(VPS_URL)-1);

   trade.SetExpertMagicNumber(12003);
   trade.SetDeviationInPoints(10);
   for(int i=0;i<12;i++) for(int j=0;j<4;j++) g_last_bars[i][j]=0;
   for(int i=0;i<50;i++) g_strat_last_bar[i]=0;

   g_day_start_balance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_day_date          = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));

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

   RunStrategies();
   RunScalp();
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

   // Risk ayarlarını parse et
   int rp=StringFind(resp,"\"risk_settings\"");
   if(rp>=0)
     {
      int rs=StringFind(resp,"{",rp);
      int re=StringFind(resp,"}",rs);
      if(rs>=0&&re>=0)
        {
         string robj=StringSubstr(resp,rs,re-rs+1);
         g_risk_enabled       = (StringFind(robj,"\"enabled\":true")>=0);
         double dl            = ExtractNum(robj,"\"daily_loss_limit\":");
         if(dl>0) g_daily_loss_limit=dl;
         double mp            = ExtractNum(robj,"\"max_open_positions\":");
         if(mp>0) g_max_open_positions=(int)mp;
         double ml            = ExtractNum(robj,"\"max_lot_per_trade\":");
         if(ml>0) g_max_lot_per_trade=ml;
        }
     }

   // Mevcut handle'ları serbest bırak (leak önlemi)
   for(int k=0;k<g_strat_count;k++)
     {
      if(g_strategies[k].handle_fast!=INVALID_HANDLE) IndicatorRelease(g_strategies[k].handle_fast);
      if(g_strategies[k].handle_slow!=INVALID_HANDLE) IndicatorRelease(g_strategies[k].handle_slow);
      if(g_strategies[k].handle_atr !=INVALID_HANDLE) IndicatorRelease(g_strategies[k].handle_atr);
      g_strategies[k].handle_fast=INVALID_HANDLE;
      g_strategies[k].handle_slow=INVALID_HANDLE;
      g_strategies[k].handle_atr =INVALID_HANDLE;
     }
   g_strat_count=0;
   int pos=0;
   while(g_strat_count<50)
     {
      int start=StringFind(resp,"{\"id\":",pos);
      if(start<0) break;
      int end=StringFind(resp,"}",start);
      if(end<0) break;
      string obj=StringSubstr(resp,start,end-start+1);

      // Scalp stratejilerini atla
      if(StringFind(obj,"SCALP")>=0) { pos=end+1; continue; }

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
      s.atr_mult         = ExtractNum(obj,"\"atr_mult\":");
      s.active           = (StringFind(obj,"\"active\":true")>=0);
      s.use_limit_entry  = (StringFind(obj,"\"use_limit_entry\":true")>=0);
      s.proximity_pct    = ExtractNum(obj,"\"proximity_pct\":");
      if(s.proximity_pct<=0) s.proximity_pct=0.10; // varsayılan %10
      s.limit_ticket     = 0;
      s.limit_placed_bar = 0;

      if(s.symbol!=""&&s.active)
        {
         // Parse kontrolü — yanlış periyot parse edilirse log'a düşer
         printf("STRATEJİ PARSE: %s fast=%d slow=%d ma=%s tf=%s sl_pip=%.1f tp_pip=%.1f lot=%.2f",
                s.id, s.fast, s.slow, s.ma_type, s.tf, s.sl_pip, s.tp_pip, s.lot);
         // Güvenlik: fast her zaman slow'dan küçük olmalı
         if(s.fast >= s.slow)
           {
            printf("HATA: fast(%d) >= slow(%d), strateji atlanıyor: %s", s.fast, s.slow, s.id);
            pos=end+1;
            continue;
           }
         ENUM_TIMEFRAMES stf=StrToTF(s.tf);
         ENUM_MA_METHOD method=MODE_EMA;
         if(s.ma_type=="SMA") method=MODE_SMA;
         else if(s.ma_type=="WMA") method=MODE_LWMA;
         s.handle_fast = iMA(s.symbol,stf,s.fast,0,method,PRICE_CLOSE);
         s.handle_slow = iMA(s.symbol,stf,s.slow,0,method,PRICE_CLOSE);
         s.handle_atr  = iATR(s.symbol,stf,14);
         printf("HANDLE: fast_handle=%d slow_handle=%d (fast_period=%d slow_period=%d)",
                s.handle_fast, s.handle_slow, s.fast, s.slow);
         // Mevcut last_bar değerini koru — yeni strateji ise şu anki bar zamanını ata
         datetime prev_last_bar = 0;
         for(int k=0; k<50; k++)
           {
            if(k < g_strat_count && g_strategies[k].id == s.id)
              { prev_last_bar = g_strat_last_bar[k]; break; }
           }
         g_strategies[g_strat_count]=s;
         g_strat_last_bar[g_strat_count] = prev_last_bar > 0 ? prev_last_bar : iTime(s.symbol,stf,0);
         g_strat_count++;
        }
      pos=end+1;
     }

   // Scalp stratejilerini de parse et
   FetchScalpStrategies(resp);
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
//| Risk kontrolü — işlem açmadan önce çağır                        |
//+------------------------------------------------------------------+
bool RiskCheck(string sym, double lot)
  {
   if(!g_risk_enabled) return true;

   // Gün başı bakiyeyi sıfırla
   datetime today = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   if(today != g_day_date)
     {
      g_day_start_balance = AccountInfoDouble(ACCOUNT_BALANCE);
      g_day_date          = today;
     }

   // Günlük zarar limiti
   double cur_balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double daily_loss  = g_day_start_balance - cur_balance;
   if(daily_loss >= g_daily_loss_limit)
     {
      printf("RiskCheck: Günlük zarar limiti aşıldı ("+DoubleToString(daily_loss,2)+" / "+DoubleToString(g_daily_loss_limit,2)+"). İşlem açılmıyor.");
      return false;
     }

   // Max açık pozisyon
   if(PositionsTotal() >= g_max_open_positions)
     {
      printf("RiskCheck: Max açık pozisyon sayısına ulaşıldı ("+IntegerToString(g_max_open_positions)+"). İşlem açılmıyor.");
      return false;
     }

   // Max lot
   if(lot > g_max_lot_per_trade)
     {
      printf("RiskCheck: Lot ("+DoubleToString(lot,2)+") max lot ("+DoubleToString(g_max_lot_per_trade,2)+") aşıyor. İşlem açılmıyor.");
      return false;
     }

   return true;
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
void UpdateTrailingSL(string sym, ulong ticket, int atr_handle, double atr_mult, double sl_pip)
  {
   if(!PositionSelectByTicket(ticket)) return;
   long   pos_type  = PositionGetInteger(POSITION_TYPE);
   double cur_price = PositionGetDouble(POSITION_PRICE_CURRENT);
   double cur_sl    = PositionGetDouble(POSITION_SL);
   double point     = SymbolInfoDouble(sym, SYMBOL_POINT);
   double trail_dist;

   if(sl_pip > 0)
     {
      // Pip trailing: stratejide girilen SL mesafesini koruyarak taşı
      trail_dist = sl_pip * 10.0 * point;
     }
   else
     {
      // ATR trailing: ATR × çarpan
      double atr_buf[1];
      if(CopyBuffer(atr_handle,0,1,1,atr_buf)<=0) return;
      trail_dist = atr_buf[0] * atr_mult;
     }

   double new_sl;
   if(pos_type==POSITION_TYPE_BUY)
     {
      new_sl = cur_price - trail_dist;
      // SL sadece yukarı taşınır (kilitlenir)
      if(new_sl > cur_sl + point)
         trade.PositionModify(ticket, new_sl, PositionGetDouble(POSITION_TP));
     }
   else
     {
      new_sl = cur_price + trail_dist;
      // SL sadece aşağı taşınır (kilitlenir)
      if(cur_sl == 0 || new_sl < cur_sl - point)
         trade.PositionModify(ticket, new_sl, PositionGetDouble(POSITION_TP));
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
      if(has_pos) UpdateTrailingSL(sym,pos_ticket,g_strategies[i].handle_atr,atr_mult,g_strategies[i].sl_pip);

      double mF_buf[3], mS_buf[3];
      // Kapanmış barları kullan: shift 1 = son kapanan bar, shift 2 = ondan önceki
      // Bar 0 (açık bar) MA değeri sürekli değişir — sahte sinyal üretir
      if(CopyBuffer(g_strategies[i].handle_fast,0,1,2,mF_buf)<=0) continue;
      if(CopyBuffer(g_strategies[i].handle_slow,0,1,2,mS_buf)<=0) continue;
      double mF_cur=mF_buf[0], mF_prev=mF_buf[1];  // shift1=cur, shift2=prev
      double mS_cur=mS_buf[0], mS_prev=mS_buf[1];

      // Geçersiz MA değeri kontrolü
      if(mF_cur==0||mS_cur==0||mF_prev==0||mS_prev==0) continue;
      if(mF_cur==EMPTY_VALUE||mS_cur==EMPTY_VALUE||mF_prev==EMPTY_VALUE||mS_prev==EMPTY_VALUE) continue;

      double point  = SymbolInfoDouble(sym, SYMBOL_POINT);
      double sl_pip = g_strategies[i].sl_pip;
      double tp_pip = g_strategies[i].tp_pip;
      double atr_buf[1]; double atr=0;
      if(CopyBuffer(g_strategies[i].handle_atr,0,1,1,atr_buf)>0) atr=atr_buf[0];
      double sl_dist = (atr>0) ? atr*atr_mult : sl_pip*10.0*point;

      // ── Kesişim tespiti ──
      datetime cur_bar=iTime(sym,tf,0);
      bool crossUp = mF_cur>mS_cur && mF_prev<=mS_prev;
      bool crossDn = mF_cur<mS_cur && mF_prev>=mS_prev;
      bool new_bar = (cur_bar != g_strat_last_bar[i]);

      // ── KESİŞİM — MARKET EMİR ──
      if(!new_bar) continue;  // Aynı barda tekrar işlem açma
      if(!crossUp && !crossDn) continue;

      printf("KESİŞİM: %s %s %s [fast_period=%d slow_period=%d] fast_val=%.5f slow_val=%.5f prev_fast=%.5f prev_slow=%.5f yön=%s",
             sym,tf_str,strat_id,fast,slow,mF_cur,mS_cur,mF_prev,mS_prev,crossUp?"BUY":"SELL");

      g_strat_last_bar[i] = cur_bar;

      if(crossUp && has_pos && pos_type==POSITION_TYPE_BUY) continue;
      if(crossDn && has_pos && pos_type==POSITION_TYPE_SELL) continue;

      if(crossUp)
        {
         if(has_pos && pos_type==POSITION_TYPE_SELL) trade.PositionClose(pos_ticket);
         if(!RiskCheck(sym, lot)) continue;
         double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
         double sl  = sl_pip>0 ? ask - sl_pip*10.0*point : ask - sl_dist;
         double tp  = tp_pip>0 ? ask + tp_pip*10.0*point : 0;
         trade.SetExpertMagicNumber(magic);
         if(trade.Buy(lot, sym, ask, sl, tp, strat_id))
            printf("BUY açıldı: "+sym+" "+strat_id+" SL="+DoubleToString(sl,5)+" TP="+DoubleToString(tp,5));
        }
      else if(crossDn)
        {
         if(has_pos && pos_type==POSITION_TYPE_BUY) trade.PositionClose(pos_ticket);
         if(!RiskCheck(sym, lot)) continue;
         double bid = SymbolInfoDouble(sym, SYMBOL_BID);
         double sl  = sl_pip>0 ? bid + sl_pip*10.0*point : bid + sl_dist;
         double tp  = tp_pip>0 ? bid - tp_pip*10.0*point : 0;
         trade.SetExpertMagicNumber(magic);
         if(trade.Sell(lot, sym, bid, sl, tp, strat_id))
            printf("SELL açıldı: "+sym+" "+strat_id+" SL="+DoubleToString(sl,5)+" TP="+DoubleToString(tp,5));
        }
     }
  }

//+------------------------------------------------------------------+
//| Scalp stratejilerini VPS'ten parse et                           |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Scalp stratejilerini VPS'ten parse et                           |
//+------------------------------------------------------------------+
void FetchScalpStrategies(string resp)
  {
   for(int k=0;k<g_scalp_count;k++)
     {
      if(g_scalps[k].handle_fast!=INVALID_HANDLE) IndicatorRelease(g_scalps[k].handle_fast);
      if(g_scalps[k].handle_slow!=INVALID_HANDLE) IndicatorRelease(g_scalps[k].handle_slow);
      g_scalps[k].handle_fast=INVALID_HANDLE;
      g_scalps[k].handle_slow=INVALID_HANDLE;
     }
   g_scalp_count=0;

   int arr_start=StringFind(resp,"scalp_strategies");
   if(arr_start<0) return;
   int bracket=StringFind(resp,"[",arr_start);
   if(bracket<0) return;

   int pos=bracket;
   while(g_scalp_count<50)
     {
      int start=StringFind(resp,"{",pos);
      if(start<0) break;
      int end=StringFind(resp,"}",start);
      if(end<0) break;
      string obj=StringSubstr(resp,start,end-start+1);
      if(StringFind(obj,"SCALP")<0) { pos=end+1; continue; }

      ScalpStrategy s;
      string key_id      = "\"id\":";
      string key_symbol  = "\"symbol\":";
      string key_tf      = "\"tf\":";
      string key_matype  = "\"ma_type\":";
      string key_lot     = "\"lot\":";
      string key_epct    = "\"engulf_pct\":";
      string key_emin    = "\"min_engulf_pip\":";
      string key_ppct    = "\"pullback_pct\":";
      string key_pbars   = "\"pullback_bars\":";
      string key_tppip   = "\"tp_pip\":";
      string key_tppct   = "\"tp_pct\":";
      string key_slpip   = "\"sl_pip\":";
      string key_mafast  = "\"ma_fast\":";
      string key_maslow  = "\"ma_slow\":";
      string key_spread  = "\"max_spread_pip\":";
      string key_mafilt  = "\"use_ma_filter\":true";
      string key_active  = "\"active\":true";

      s.id            = ExtractStr(obj,key_id);
      s.symbol        = ExtractStr(obj,key_symbol);
      s.tf            = ExtractStr(obj,key_tf);
      s.ma_type       = ExtractStr(obj,key_matype);
      s.lot           = ExtractNum(obj,key_lot);
      s.engulf_pct    = ExtractNum(obj,key_epct);
      s.min_engulf_pip= ExtractNum(obj,key_emin);
      s.pullback_pct  = ExtractNum(obj,key_ppct);
      s.pullback_bars = (int)ExtractNum(obj,key_pbars);
      s.tp_pip        = ExtractNum(obj,key_tppip);
      s.tp_pct        = ExtractNum(obj,key_tppct);
      s.sl_pip        = ExtractNum(obj,key_slpip);
      s.ma_fast       = (int)ExtractNum(obj,key_mafast);
      s.ma_slow       = (int)ExtractNum(obj,key_maslow);
      s.max_spread_pip= ExtractNum(obj,key_spread);
      s.use_ma_filter = (StringFind(obj,key_mafilt)>=0);
      s.active        = (StringFind(obj,key_active)>=0);

      if(s.engulf_pct<=0)    s.engulf_pct=1.0;
      if(s.pullback_pct<=0)  s.pullback_pct=0.5;
      if(s.pullback_bars<=0) s.pullback_bars=3;
      if(s.tp_pct<=0)        s.tp_pct=1.0;

      s.engulf_detected = false;
      s.engulf_dir      = 0;
      s.pullback_count  = 0;
      s.engulf_bar      = 0;
      s.handle_fast     = INVALID_HANDLE;
      s.handle_slow     = INVALID_HANDLE;

      if(s.symbol!=""&&s.active)
        {
         ENUM_TIMEFRAMES stf=StrToTF(s.tf);
         if(s.use_ma_filter&&s.ma_fast>0&&s.ma_slow>0)
           {
            ENUM_MA_METHOD method=MODE_EMA;
            if(s.ma_type=="SMA") method=MODE_SMA;
            else if(s.ma_type=="WMA") method=MODE_LWMA;
            s.handle_fast=iMA(s.symbol,stf,s.ma_fast,0,method,PRICE_CLOSE);
            s.handle_slow=iMA(s.symbol,stf,s.ma_slow,0,method,PRICE_CLOSE);
           }
         g_scalps[g_scalp_count]=s;
         g_scalp_count++;
         printf("SCALP PARSE: %s %s tp=%.1f sl=%.1f engulf=%.0f%%",
                s.id,s.tf,s.tp_pip,s.sl_pip,s.engulf_pct*100);
        }
      pos=end+1;
     }
  }

void RunScalp()
  {
   if(!g_auto_mode||g_scalp_count==0) return;
   for(int i=0;i<g_scalp_count;i++)
     {
      string sym   = g_scalps[i].symbol;
      string tfstr = g_scalps[i].tf;
      double lot   = g_scalps[i].lot;
      ENUM_TIMEFRAMES tf=StrToTF(tfstr);
      double point = SymbolInfoDouble(sym,SYMBOL_POINT);
      int    magic = StratMagic(g_scalps[i].id);
      double bid   = SymbolInfoDouble(sym,SYMBOL_BID);
      double ask   = SymbolInfoDouble(sym,SYMBOL_ASK);

      // Spread kontrolu
      if(g_scalps[i].max_spread_pip>0)
        {
         double spread=(ask-bid)/point/10.0;
         if(spread>g_scalps[i].max_spread_pip) continue;
        }

      // MA yon filtresi
      int ma_dir=0;
      if(g_scalps[i].use_ma_filter&&
         g_scalps[i].handle_fast!=INVALID_HANDLE&&
         g_scalps[i].handle_slow!=INVALID_HANDLE)
        {
         double mf[1],ms[1];
         if(CopyBuffer(g_scalps[i].handle_fast,0,1,1,mf)>0&&
            CopyBuffer(g_scalps[i].handle_slow,0,1,1,ms)>0)
            ma_dir=(mf[0]>ms[0])?1:-1;
        }

      datetime cur_bar=iTime(sym,tf,0);

      // Acik pozisyon var mi?
      long pos_type=0; ulong pos_ticket=0;
      bool has_pos=HasPosition(sym,magic,pos_type,pos_ticket);
      if(has_pos) continue;

      // Bekleyen limit emir kontrolu
      if(g_scalps[i].engulf_detected && g_scalps[i].pullback_count > 0)
        {
         // Limit emir hala bekliyor mu?
         bool order_exists=false;
         for(int oi=0;oi<OrdersTotal();oi++)
           {
            ulong otkt=OrderGetTicket(oi);
            if(otkt==0) continue;
            if((long)OrderGetInteger(ORDER_MAGIC)==magic &&
               OrderGetString(ORDER_SYMBOL)==sym)
              { order_exists=true; break; }
           }

         if(order_exists)
           {
            // Engulfing high/low kirildi mi? — iptal et
            double inv_level = (g_scalps[i].engulf_dir==1) ?
                               g_scalps[i].engulf_low :   // BUY: low kirilirsa iptal
                               g_scalps[i].engulf_high;   // SELL: high kirilirsa iptal
            bool invalidated = (g_scalps[i].engulf_dir==1) ?
                               (bid < inv_level) :
                               (ask > inv_level);
            if(invalidated)
              {
               for(int oi=OrdersTotal()-1;oi>=0;oi--)
                 {
                  ulong otkt=OrderGetTicket(oi);
                  if(otkt==0) continue;
                  if((long)OrderGetInteger(ORDER_MAGIC)==magic &&
                     OrderGetString(ORDER_SYMBOL)==sym)
                     trade.OrderDelete(otkt);
                 }
               g_scalps[i].engulf_detected=false;
               g_scalps[i].pullback_count=0;
               printf("ENGULFING iptal (high/low kirildi): %s",sym);
              }

            // Max bar suresi doldu mu?
            g_scalps[i].pullback_count++;
            int max_ticks=g_scalps[i].pullback_bars*300;
            if(g_scalps[i].pullback_count>max_ticks)
              {
               for(int oi=OrdersTotal()-1;oi>=0;oi--)
                 {
                  ulong otkt=OrderGetTicket(oi);
                  if(otkt==0) continue;
                  if((long)OrderGetInteger(ORDER_MAGIC)==magic &&
                     OrderGetString(ORDER_SYMBOL)==sym)
                     trade.OrderDelete(otkt);
                 }
               g_scalps[i].engulf_detected=false;
               g_scalps[i].pullback_count=0;
               printf("ENGULFING limit suresi doldu: %s",sym);
              }
            continue;
           }
         else
           {
            // Emir yok — tetiklendi veya iptal oldu
            g_scalps[i].engulf_detected=false;
            g_scalps[i].pullback_count=0;
            continue;
           }
        }

      // Yeni engulfing tespiti — yeni bar acildiysa kontrol et
      if(g_scalps[i].engulf_detected) continue; // zaten var, yukarida islendi

      double c1o=iOpen(sym,tf,1),  c1h=iHigh(sym,tf,1);
      double c1l=iLow(sym,tf,1),   c1c=iClose(sym,tf,1);
      double c2o=iOpen(sym,tf,2),  c2h=iHigh(sym,tf,2);
      double c2l=iLow(sym,tf,2),   c2c=iClose(sym,tf,2);

      // Govde hesapla (igne haric)
      double c1body=MathAbs(c1c-c1o);
      double c2body=MathAbs(c2c-c2o);
      double minbody=g_scalps[i].min_engulf_pip*10.0*point;

      if(c1body<minbody) continue; // engulfing mumu min buyuklukte olmali
      if(c2body<c1body*0.6) continue; // yutulan mum engulfing in en az %60 i olmali

      double ratio=c1body/c2body;
      bool bull=(c2c<c2o)&&(c1c>c1o)&&(c1o<=c2c)&&(c1c>=c2o)&&(ratio>=g_scalps[i].engulf_pct);
      bool bear=(c2c>c2o)&&(c1c<c1o)&&(c1o>=c2c)&&(c1c<=c2o)&&(ratio>=g_scalps[i].engulf_pct);

      if(ma_dir==1&&bear) bear=false;
      if(ma_dir==-1&&bull) bull=false;
      if(!bull&&!bear) continue;

      // Limit emir seviyesi — govdenin pullback_pct'si kadar
      double ebody = c1body; // govde (igne haric)
      double limit_price, sl_price, tp_price;
      double sl_dist = g_scalps[i].sl_pip>0 ? g_scalps[i].sl_pip*10.0*point : ebody;
      double tp_dist = g_scalps[i].tp_pip>0 ? g_scalps[i].tp_pip*10.0*point : ebody*g_scalps[i].tp_pct;

      if(!RiskCheck(sym,lot)) continue;
      trade.SetExpertMagicNumber(magic);

      if(bull)
        {
         // BUY: govdenin pullback_pct kadar asagisi
         limit_price = c1c + ebody * g_scalps[i].pullback_pct; // c1c dusuk, yukari cekilme
         // Ama c1c BUY govdesinin alt noktasi, yukariya dogru cekilme
         limit_price = c1o - ebody * (1.0 - g_scalps[i].pullback_pct); // asagidan yukari
         limit_price = NormalizeDouble(c1c + ebody * (1.0 - g_scalps[i].pullback_pct), (int)SymbolInfoInteger(sym,SYMBOL_DIGITS));
         sl_price    = NormalizeDouble(limit_price - sl_dist, (int)SymbolInfoInteger(sym,SYMBOL_DIGITS));
         tp_price    = NormalizeDouble(limit_price + tp_dist, (int)SymbolInfoInteger(sym,SYMBOL_DIGITS));
         if(trade.BuyLimit(lot,limit_price,sym,sl_price,tp_price,ORDER_TIME_GTC,0,g_scalps[i].id))
           {
            g_scalps[i].engulf_detected = true;
            g_scalps[i].engulf_dir      = 1;
            g_scalps[i].engulf_high     = c1h;
            g_scalps[i].engulf_low      = c1l;
            g_scalps[i].engulf_open     = c1o;
            g_scalps[i].engulf_close    = c1c;
            g_scalps[i].pullback_count  = 1;
            g_scalps[i].engulf_bar      = cur_bar;
            printf("SCALP BUY LIMIT: %s @ %.5f SL:%.5f TP:%.5f ratio:%.2f",sym,limit_price,sl_price,tp_price,ratio);
           }
        }
      else if(bear)
        {
         // SELL: govdenin pullback_pct kadar yukari cekilme seviyesi
         // c1o yuksek, c1c dusuk — govdenin %pct'si yukari = c1c + ebody*pct
         limit_price = NormalizeDouble(c1c + ebody * g_scalps[i].pullback_pct, (int)SymbolInfoInteger(sym,SYMBOL_DIGITS));
         sl_price    = NormalizeDouble(limit_price + sl_dist, (int)SymbolInfoInteger(sym,SYMBOL_DIGITS));
         tp_price    = NormalizeDouble(limit_price - tp_dist, (int)SymbolInfoInteger(sym,SYMBOL_DIGITS));
         if(trade.SellLimit(lot,limit_price,sym,sl_price,tp_price,ORDER_TIME_GTC,0,g_scalps[i].id))
           {
            g_scalps[i].engulf_detected = true;
            g_scalps[i].engulf_dir      = -1;
            g_scalps[i].engulf_high     = c1h;
            g_scalps[i].engulf_low      = c1l;
            g_scalps[i].engulf_open     = c1o;
            g_scalps[i].engulf_close    = c1c;
            g_scalps[i].pullback_count  = 1;
            g_scalps[i].engulf_bar      = cur_bar;
            printf("SCALP SELL LIMIT: %s @ %.5f SL:%.5f TP:%.5f ratio:%.2f",sym,limit_price,sl_price,tp_price,ratio);
           }
        }
     }
  }
//+------------------------------------------------------------------+