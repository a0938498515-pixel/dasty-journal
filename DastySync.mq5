//+------------------------------------------------------------------+
//|                                                   DastySync.mq5  |
//|  Отправляет закрытые позиции MetaTrader 5 в Dasty Journal         |
//|  вместе со свечами M1/M5/M15/H1/H4 вокруг каждой сделки.          |
//|                                                                  |
//|  Советник ничего не торгует: он только читает историю счёта.     |
//|  Перед запуском: Сервис → Настройки → Советники →                |
//|  «Разрешить WebRequest для следующих URL» → добавить адрес        |
//|  проекта Supabase (тот же, что в параметре InpUrl).              |
//+------------------------------------------------------------------+
#property copyright "Dasty Journal"
#property version   "1.30"
#property description "Синхронизация закрытых сделок MT5 с Dasty Journal"

input string   InpUrl      = "";                   // Адрес проекта Supabase (https://xxxx.supabase.co)
input string   InpKey      = "";                   // Ключ проекта (Publishable key или anon public)
input string   InpToken    = "";                   // Ключ синхронизации из журнала
input datetime InpFrom     = D'2024.01.01 00:00';  // Отправлять сделки, закрытые после этой даты
input int      InpInterval = 60;                   // Проверять новые сделки каждые N секунд
input bool     InpBars     = true;                 // Отправлять свечи для графика сделки

#define BATCH 5

long     g_sent[];          // уже отправленные позиции
long     g_waitId[];        // позиции, для которых терминал ещё догружает свечи
int      g_waitCnt[];
string   g_file   = "";
string   g_url    = "";
datetime g_last   = 0;      // последняя удачная связь
datetime g_beat   = 0;      // последняя отправка данных счёта
int      g_total  = 0;      // отправлено за сеанс
string   g_status = "запуск…";
string   g_lastOpen = "";   // последний отправленный список открытых позиций
int      g_openCnt = 0;

//+------------------------------------------------------------------+
int OnInit()
  {
   g_url = InpUrl;
   StringTrimLeft(g_url);
   StringTrimRight(g_url);
   while(StringLen(g_url) > 0 && StringSubstr(g_url, StringLen(g_url) - 1) == "/")
      g_url = StringSubstr(g_url, 0, StringLen(g_url) - 1);

   if(StringLen(g_url) < 12 || StringLen(InpKey) < 20 || StringLen(InpToken) < 20)
     {
      Alert("DastySync: заполните InpUrl, InpKey и InpToken во входных параметрах советника.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(MQLInfoInteger(MQL_TESTER))
     {
      Alert("DastySync не работает в тестере стратегий — запустите его на обычном графике.");
      return(INIT_FAILED);
     }
   g_file = "DastySync2_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + ".txt";   // v1.2: новый файл — сделки отправятся заново со свечами M15–W1
   LoadSent();
   EventSetTimer(MathMax(15, InpInterval));
   Sync();
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   Comment("");
  }

void OnTimer()
  {
   Sync();
  }

void OnTick()
  {
  }

void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
  {
// новая сделка в истории — проверяем через 2 секунды, не дожидаясь таймера
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
     {
      EventKillTimer();
      EventSetTimer(2);
     }
  }

//+------------------------------------------------------------------+
//| Основной цикл: найти закрытые позиции и отправить новые          |
//+------------------------------------------------------------------+
void Sync()
  {
   EventKillTimer();
   EventSetTimer(MathMax(15, InpInterval));
   if(!TerminalInfoInteger(TERMINAL_CONNECTED))
     {
      Show("нет связи с торговым сервером");
      return;
     }
   if(!HistorySelect(InpFrom, TimeCurrent() + 86400))
     {
      Show("не удалось загрузить историю");
      return;
     }

   string op = OpenJson();

// 1. Собираем ID позиций, у которых есть сделки закрытия
   long ids[];
   int  n = 0;
   int  total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0)
         continue;
      long entry = HistoryDealGetInteger(d, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY && entry != DEAL_ENTRY_INOUT)
         continue;
      long pid = HistoryDealGetInteger(d, DEAL_POSITION_ID);
      if(pid <= 0 || InArr(g_sent, pid) || InArr(ids, pid))
         continue;
      ArrayResize(ids, n + 1);
      ids[n++] = pid;
     }

// 2. Формируем и отправляем пачками
   string batch = "";
   long   bIds[];
   int    bn = 0;
   int    sentNow = 0;
   for(int i = 0; i < n; i++)
     {
      string js = "";
      int st = BuildPosition(ids[i], js);
      if(st == 0)
         continue;              // позиция ещё не закрыта полностью
      if(st == 2)
        {
         if(WaitMore(ids[i]))
            continue;           // свечи догружаются — попробуем в следующий раз
         js = "";
         BuildPosition(ids[i], js, true);
        }
      batch += (bn > 0 ? "," : "") + js;
      ArrayResize(bIds, bn + 1);
      bIds[bn++] = ids[i];
      if(bn >= BATCH)
        {
         if(!Send(batch, op))
            return;
         MarkSent(bIds, bn);
         sentNow += bn;
         batch = "";
         bn = 0;
         ArrayResize(bIds, 0);
        }
     }
   if(bn > 0)
     {
      if(!Send(batch, op))
         return;
      MarkSent(bIds, bn);
      sentNow += bn;
     }

// 3. Открытые позиции — каждую проверку, пока они есть (и один раз, когда все закрыты);
//    без открытых позиций — раз в 10 минут обновляем баланс счёта
   if(sentNow == 0 && (op != "[]" || op != g_lastOpen || TimeCurrent() - g_beat >= 600))
      if(!Send("", op))
         return;

   g_total += sentNow;
   Show(sentNow > 0 ? "отправлено новых сделок: " + IntegerToString(sentNow) : "новых сделок нет");
  }

//+------------------------------------------------------------------+
//| 0 — позиция не закрыта, 1 — готово, 2 — свечи ещё не загружены   |
//+------------------------------------------------------------------+
int BuildPosition(long pid, string &js, bool force = false)
  {
   if(!HistorySelectByPosition(pid))
      return 0;
   int total = HistoryDealsTotal();
   double vin = 0, vout = 0, pin = 0, pout = 0, profit = 0, comm = 0, swap = 0, fee = 0, sl = 0, tp = 0, slClose = 0;
   datetime ot = 0, ct = 0;
   string sym = "";
   long type = -1, lastReason = -1;
   int nin = 0;

   for(int i = 0; i < total; i++)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0)
         continue;
      long dt = HistoryDealGetInteger(d, DEAL_TYPE);
      if(dt != DEAL_TYPE_BUY && dt != DEAL_TYPE_SELL)
         continue;
      long     entry = HistoryDealGetInteger(d, DEAL_ENTRY);
      double   vol   = HistoryDealGetDouble(d, DEAL_VOLUME);
      double   pr    = HistoryDealGetDouble(d, DEAL_PRICE);
      datetime t     = (datetime)HistoryDealGetInteger(d, DEAL_TIME);
      profit += HistoryDealGetDouble(d, DEAL_PROFIT);
      comm   += HistoryDealGetDouble(d, DEAL_COMMISSION);
      swap   += HistoryDealGetDouble(d, DEAL_SWAP);
      fee    += HistoryDealGetDouble(d, DEAL_FEE);
      if(sym == "")
         sym = HistoryDealGetString(d, DEAL_SYMBOL);

      if(entry == DEAL_ENTRY_IN)
        {
         if(nin == 0)
           {
            ot   = t;
            type = dt;
            sl   = HistoryDealGetDouble(d, DEAL_SL);
            tp   = HistoryDealGetDouble(d, DEAL_TP);
           }
         vin += vol;
         pin += pr * vol;
         nin++;
        }
      else
        {
         vout += vol;
         pout += pr * vol;
         if(t >= ct)
           {
            ct = t;
            lastReason = HistoryDealGetInteger(d, DEAL_REASON);
           }
         double s2 = HistoryDealGetDouble(d, DEAL_SL);
         if(s2 > 0)
            slClose = s2;
         if(tp <= 0)
            tp = HistoryDealGetDouble(d, DEAL_TP);
        }
     }
   if(nin == 0 || vin <= 0 || vout + 1e-8 < vin || ct == 0)
      return 0;

   double op = pin / vin, cp = pout / vout;
   string slSrc = "open";
   if(sl <= 0 && slClose > 0)
     {
      sl = slClose;
      slSrc = "close";
     }

   SymbolSelect(sym, true);
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   if(digits <= 0)
      digits = 5;
   double risk = 0;
   if(sl > 0)
     {
      double ts = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
      double tv = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE_LOSS);
      if(tv <= 0)
         tv = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
      if(ts > 0 && tv > 0)
         risk = MathAbs(op - sl) / ts * tv * vin;
     }
   // маржа (по текущему плечу счёта) и номинал позиции в валюте счёта
   double margin = 0;
   if(!OrderCalcMargin(type == DEAL_TYPE_BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, sym, vin, op, margin))
      margin = 0;
   double notional = 0;
     {
      double ts2 = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
      double tv2 = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
      if(ts2 > 0 && tv2 > 0)
         notional = op * vin * tv2 / ts2;
     }
   string reason = "other";
   if(lastReason == DEAL_REASON_SL)
      reason = "sl";
   else
      if(lastReason == DEAL_REASON_TP)
         reason = "tp";
      else
         if(lastReason == DEAL_REASON_SO)
            reason = "so";
         else
            if(lastReason == DEAL_REASON_CLIENT || lastReason == DEAL_REASON_MOBILE || lastReason == DEAL_REASON_WEB)
               reason = "manual";
            else
               if(lastReason == DEAL_REASON_EXPERT)
                  reason = "expert";
   long off = ServerOffset();

   js = "{\"pos\":" + IntegerToString(pid) + ",\"data\":{"
        + "\"sym\":\"" + Esc(sym) + "\""
        + ",\"type\":\"" + (type == DEAL_TYPE_BUY ? "buy" : "sell") + "\""
        + ",\"vol\":" + DoubleToString(vin, 2)
        + ",\"ot\":" + IntegerToString((long)ot - off)
        + ",\"ct\":" + IntegerToString((long)ct - off)
        + ",\"op\":" + DoubleToString(op, digits + 1)
        + ",\"cp\":" + DoubleToString(cp, digits + 1)
        + ",\"sl\":" + DoubleToString(sl, digits)
        + ",\"slSrc\":\"" + slSrc + "\""
        + ",\"tp\":" + DoubleToString(tp, digits)
        + ",\"profit\":" + DoubleToString(profit, 2)
        + ",\"comm\":" + DoubleToString(comm, 2)
        + ",\"swap\":" + DoubleToString(swap, 2)
        + ",\"fee\":" + DoubleToString(fee, 2)
        + ",\"risk\":" + DoubleToString(risk, 2)
        + ",\"margin\":" + DoubleToString(margin, 2)
        + ",\"notional\":" + DoubleToString(notional, 2)
        + ",\"reason\":\"" + reason + "\""
        + ",\"digits\":" + IntegerToString(digits)
        + ",\"deals\":" + IntegerToString(total)
        + "}";

   if(InpBars)
     {
      int missing = 0;
      string bars = BarsJson(sym, ot, ct, digits, off, missing);
      if(missing > 0 && !force)
         return 2;
      js += ",\"bars\":" + bars;
     }
   js += "}";
   return 1;
  }

//+------------------------------------------------------------------+
//| Свечи вокруг сделки: 100 свечей до входа и 50 после выхода       |
//+------------------------------------------------------------------+
string BarsJson(string sym, datetime ot, datetime ct, int digits, long off, int &missing)
  {
   ENUM_TIMEFRAMES tfs[6] = {PERIOD_M15, PERIOD_M30, PERIOD_H1, PERIOD_H4, PERIOD_D1, PERIOD_W1};
   string names[6] = {"M15", "M30", "H1", "H4", "D1", "W1"};
   string out = "{";
   bool first = true;
   missing = 0;
   for(int k = 0; k < 6; k++)
     {
      int ps = PeriodSeconds(tfs[k]);
      if((ct - ot) / ps > 300)
         continue;                       // слишком длинная сделка для этого таймфрейма
      MqlRates r[];
      int got = CopyRates(sym, tfs[k], ot - 100 * ps, ct + 50 * ps, r);
      if(got < 3)
        {
         missing++;
         continue;
        }
      string a = "";
      for(int i = 0; i < got; i++)
        {
         if(i > 0)
            a += ",";
         a += "[" + IntegerToString((long)r[i].time - off) + ","
              + DoubleToString(r[i].open, digits) + ","
              + DoubleToString(r[i].high, digits) + ","
              + DoubleToString(r[i].low, digits) + ","
              + DoubleToString(r[i].close, digits) + "]";
        }
      out += (first ? "" : ",") + "\"" + names[k] + "\":[" + a + "]";
      first = false;
     }
   return out + "}";
  }

//+------------------------------------------------------------------+
//| Отправка в Supabase (функция mt5_push)                           |
//+------------------------------------------------------------------+
bool Send(string items, string open)
  {
   string acc = "{\"login\":" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN))
                + ",\"server\":\"" + Esc(AccountInfoString(ACCOUNT_SERVER)) + "\""
                + ",\"company\":\"" + Esc(AccountInfoString(ACCOUNT_COMPANY)) + "\""
                + ",\"currency\":\"" + Esc(AccountInfoString(ACCOUNT_CURRENCY)) + "\""
                + ",\"balance\":" + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2)
                + ",\"equity\":" + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2)
                + ",\"ea\":\"1.30\"}";
   string body = "{\"p_token\":\"" + Esc(InpToken) + "\",\"p_account\":" + acc + ",\"p_trades\":[" + items + "],\"p_open\":" + open + "}";
   string headers = "Content-Type: application/json\r\napikey: " + InpKey + "\r\n";
   char data[], res[];
   string rh;
   int len = StringToCharArray(body, data, 0, WHOLE_ARRAY, CP_UTF8);
   if(len > 0)
      ArrayResize(data, len - 1);   // убираем завершающий ноль
   ResetLastError();
   int code = WebRequest("POST", g_url + "/rest/v1/rpc/mt5_push", headers, 20000, data, res, rh);
   if(code == -1)
     {
      int e = GetLastError();
      if(e == 4014)
         Show("разрешите WebRequest для " + g_url + " (Сервис → Настройки → Советники)");
      else
         Show("ошибка сети " + IntegerToString(e) + ", повторю позже");
      return false;
     }
   if(code != 200)
     {
      string txt = CharArrayToString(res, 0, WHOLE_ARRAY, CP_UTF8);
      if(StringFind(txt, "invalid sync token") >= 0)
         Show("неверный ключ синхронизации — получите новый в журнале (Настройки → Облако и MT5)");
      else
         Show("сервер ответил " + IntegerToString(code) + ": " + StringSubstr(txt, 0, 160));
      return false;
     }
   g_last = TimeLocal();
   g_beat = TimeCurrent();
   g_lastOpen = open;
   return true;
  }

//+------------------------------------------------------------------+
//| Список открытых позиций (JSON)                                   |
//+------------------------------------------------------------------+
string OpenJson()
  {
   long off = ServerOffset();
   string a = "";
   int n = PositionsTotal();
   g_openCnt = 0;
   for(int i = 0; i < n && i < 200; i++)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0)
         continue;
      string sym = PositionGetString(POSITION_SYMBOL);
      int dg = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      if(dg <= 0)
         dg = 5;
      string side = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? "buy" : "sell";
      a += (a == "" ? "" : ",");
      a += "{\"pos\":" + IntegerToString(PositionGetInteger(POSITION_IDENTIFIER))
           + ",\"sym\":\"" + Esc(sym) + "\""
           + ",\"type\":\"" + side + "\""
           + ",\"vol\":" + DoubleToString(PositionGetDouble(POSITION_VOLUME), 2)
           + ",\"ot\":" + IntegerToString((long)PositionGetInteger(POSITION_TIME) - off)
           + ",\"op\":" + DoubleToString(PositionGetDouble(POSITION_PRICE_OPEN), dg)
           + ",\"cp\":" + DoubleToString(PositionGetDouble(POSITION_PRICE_CURRENT), dg)
           + ",\"sl\":" + DoubleToString(PositionGetDouble(POSITION_SL), dg)
           + ",\"tp\":" + DoubleToString(PositionGetDouble(POSITION_TP), dg)
           + ",\"swap\":" + DoubleToString(PositionGetDouble(POSITION_SWAP), 2)
           + ",\"profit\":" + DoubleToString(PositionGetDouble(POSITION_PROFIT), 2)
           + ",\"digits\":" + IntegerToString(dg) + "}";
      g_openCnt++;
     }
   return "[" + a + "]";
  }

//+------------------------------------------------------------------+
//| Вспомогательные функции                                          |
//+------------------------------------------------------------------+
long ServerOffset()
  {
// разница времени сервера брокера и UTC, округлённая до 30 минут
   long o = (long)(TimeTradeServer() - TimeGMT());
   return (long)MathRound(o / 1800.0) * 1800;
  }

string Esc(string s)
  {
   StringReplace(s, "\\", "\\\\");
   StringReplace(s, "\"", "\\\"");
   StringReplace(s, "\r", " ");
   StringReplace(s, "\n", " ");
   StringReplace(s, "\t", " ");
   return s;
  }

bool InArr(const long &a[], long v)
  {
   int n = ArraySize(a);
   for(int i = 0; i < n; i++)
      if(a[i] == v)
         return true;
   return false;
  }

bool WaitMore(long pid)
  {
   int n = ArraySize(g_waitId);
   for(int i = 0; i < n; i++)
      if(g_waitId[i] == pid)
        {
         g_waitCnt[i]++;
         return g_waitCnt[i] <= 3;
        }
   ArrayResize(g_waitId, n + 1);
   ArrayResize(g_waitCnt, n + 1);
   g_waitId[n] = pid;
   g_waitCnt[n] = 1;
   return true;
  }

void LoadSent()
  {
   ArrayResize(g_sent, 0);
   int h = FileOpen(g_file, FILE_READ | FILE_TXT | FILE_ANSI);
   if(h == INVALID_HANDLE)
      return;
   while(!FileIsEnding(h))
     {
      string s = FileReadString(h);
      long v = StringToInteger(s);
      if(v > 0)
        {
         int n = ArraySize(g_sent);
         ArrayResize(g_sent, n + 1);
         g_sent[n] = v;
        }
     }
   FileClose(h);
  }

void MarkSent(const long &ids[], int cnt)
  {
   int h = FileOpen(g_file, FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(h != INVALID_HANDLE)
      FileSeek(h, 0, SEEK_END);
   for(int i = 0; i < cnt; i++)
     {
      int n = ArraySize(g_sent);
      ArrayResize(g_sent, n + 1);
      g_sent[n] = ids[i];
      if(h != INVALID_HANDLE)
         FileWriteString(h, IntegerToString(ids[i]) + "\r\n");
     }
   if(h != INVALID_HANDLE)
      FileClose(h);
  }

void Show(string s)
  {
   g_status = s;
   Comment("DastySync · счёт ", AccountInfoInteger(ACCOUNT_LOGIN), "\n",
           "Статус: ", g_status, "\n",
           "Отправлено за сеанс: ", g_total, " · всего: ", ArraySize(g_sent), " · открытых позиций: ", g_openCnt, "\n",
           "Последняя связь: ", (g_last > 0 ? TimeToString(g_last, TIME_DATE | TIME_MINUTES) : "—"));
  }
//+------------------------------------------------------------------+
