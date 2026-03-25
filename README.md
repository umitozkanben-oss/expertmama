# ExpertMAMA Cloud

MT5 EA → Contabo VPS (FastAPI) → GitHub Pages Dashboard

## Repo Yapısı

```
expertmama/
├── main.py                          # FastAPI backend (VPS'e gider)
├── install.sh                       # VPS kurulum scripti
├── requirements.txt                 # Python bağımlılıkları
├── dashboard/
│   └── index.html                   # Web dashboard (GitHub Pages)
├── mql5/
│   └── ExpertMAMA_Cloud.mq5         # MT5 EA
└── .github/
    └── workflows/
        └── deploy.yml               # Otomatik deploy
```

## Kurulum Adımları

### 1. GitHub Repo

```bash
git init
git add .
git commit -m "initial"
git remote add origin https://github.com/KULLANICI/expertmama.git
git push -u origin main
```

GitHub Pages'i aktif edin:
- Settings → Pages → Source: GitHub Actions

### 2. VPS Kurulumu

```bash
# VPS'e SSH ile bağlan
ssh root@VPS_IP

# Repoyu çek
git clone https://github.com/KULLANICI/expertmama.git /opt/expertmama
cd /opt/expertmama

# Kurulum scriptini çalıştır
chmod +x install.sh
sudo ./install.sh
```

### 3. GitHub Secrets Ayarla

Settings → Secrets → Actions:
- `VPS_HOST` → VPS IP adresi
- `VPS_USER` → root
- `VPS_PASSWORD` → VPS şifreniz

### 4. MT5 EA Kurulumu

1. `ExpertMAMA_Cloud.mq5` → `MQL5/Experts/` klasörüne koy
2. MetaEditor'de aç ve derle (F7)
3. Grafiğe sürükle
4. `Inp_VPS_IP` = VPS IP adresiniz
5. MT5 → Tools → Options → Expert Advisors → WebRequest URL ekle:
   ```
   http://VPS_IP:8765
   ```

### 5. Dashboard'a Eriş

- GitHub Pages: `https://KULLANICI.github.io/expertmama`
- VPS direkt: `http://VPS_IP`

Dashboard'da VPS URL girin: `http://VPS_IP:8765` ve Bağlan'a tıklayın.

## API Endpointleri

| Endpoint | Method | Açıklama |
|---|---|---|
| `/tick` | POST | MT5 canlı tick verisi |
| `/bars` | POST | MT5 bar (OHLCV) verisi |
| `/positions` | POST | Açık pozisyonlar + geçmiş |
| `/data` | GET | Dashboard için tüm veri |
| `/bars/{symbol}` | GET | Belirli sembol bar verisi |
| `/health` | GET | Servis durumu |

## Özellikler

- Tüm para pariteleri
- SMA / EMA / WMA MA optimizasyonu
- Brute-force backtest motoru (tüm fast/slow kombinasyonları)
- MA bazlı / ATR bazlı / Sabit trailing SL görselleştirmesi
- Canlı equity eğrisi
- Açık pozisyonlar ve işlem geçmişi
