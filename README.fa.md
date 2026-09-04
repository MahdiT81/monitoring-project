# پایش برنامهٔ کاربردی وب با Prometheus و Grafana

[English](README.md) | فارسی

یک پروژهٔ عملی DevOps که پایش سرتاسری (End-to-End) یک برنامهٔ وب را با استفاده از **Docker**، **Prometheus** و **Grafana** نشان می‌دهد.

برنامهٔ تحت پایش، یک API سادهٔ Flask است که تنها هدفش *تولید داده‌های ترافیک واقع‌گرایانه* است (تأخیرهای متغیر و خطاهای گاه‌به‌گاه). تمرکز اصلی پروژه روی خودِ پشتهٔ پایش است.

## معماری

```
                    ┌───────────────────────────────────────────────────┐
                    │                  Docker network                   │
                    │                                                   │
   :5000           │  ┌────────┐  scrape  ┌────────────┐  alerts      │
  Browser ─────────┼─►│ WebApp │◄─────────│ Prometheus │──────────┐   │
                    │  │ (Flask)│  /metrics│    :9090   │          ▼   │
                    │  └────┬───┘          └─▲───▲──▲───┘  ┌────────────┐│
                    │       │ logs           │   │  │      │Alertmanager││
                    │  ┌────▼───┐     probes  │   │  │      └────────────┘
                    │  │ Promtail│            │   │  │                   │
                    │  └────┬───┘   ┌─────────┴┐  │  └► node-exporter   │
                    │  ┌────▼───┐   │ Blackbox │  │     cadvisor        │
                    │  │  Loki  │   └──────────┘  │                     │
                    │  └────┬───┘                 │ queries             │
                    │       │               ┌─────┴──────┐              │
   :3000           │       └──────────────►│   Grafana  │              │
  Browser ─────────┼───────────────────────│    :3000   │              │
                    │                       └────────────┘              │
                    └───────────────────────────────────────────────────┘
```

| سرویس | وظیفه | پورت |
|---|---|---|
| `webapp` | API فلاسک با endpoint سفارشیِ `/metrics` (شمارنده، هیستوگرام و گیج)؛ endpointهایش ترافیک واقع‌گرایانه تولید می‌کنند | 5000 |
| `prometheus` | جمع‌آوری (Scrape) و ذخیرهٔ متریک‌ها، ارزیابی قواعد هشدار | 9090 |
| `alertmanager` | گروه‌بندی، حذف تکرار و تحویل هشدارهای فعال‌شده (آمادهٔ Webhook/ایمیل) | 9093 |
| `grafana` | داشبوردها: متریک‌ها + لاگ‌های زنده (به‌صورت خودکار Provision می‌شود) | 3000 |
| `loki` + `promtail` | تجمیع لاگ — Promtail با اتصال به Docker Socket لاگ همهٔ کانتینرها را به Loki می‌فرستد | 13100 (میزبان) → 3100 |
| `node-exporter` | متریک‌های سطح میزبان (CPU، RAM، دیسک) | 9100 |
| `cadvisor` | متریک‌های مصرف منابع هر کانتینر | 8080 |
| `blackbox-exporter` | بررسی سلامت HTTP از بیرون (پروب روی endpointهای `/health`) | 9115 |

## متریک‌های برنامهٔ وب

| متریک | نوع | معنا |
|---|---|---|
| `app_http_requests_total{method, endpoint, status}` | Counter (شمارنده) | تعداد کل درخواست‌ها به تفکیک endpoint و کد وضعیت |
| `app_http_request_duration_seconds_bucket{endpoint}` | Histogram (هیستوگرام) | توزیع تأخیر درخواست‌ها (امکان محاسبهٔ p50/p95/p99) |
| `app_http_requests_in_progress{endpoint}` | Gauge (گیج) | درخواست‌هایی که هم‌اکنون در حال سرو شدن هستند |
| `app_info{version}` | Gauge | اطلاعات نسخهٔ برنامه |

## Endpointهای تولید ترافیک

- `GET /` — سریع (حدود ۱۰ تا ۸۰ میلی‌ثانیه)
- `GET /api/users` — تأخیر متوسط
- `GET /api/orders` — **حدود ۱۰٪ درخواست‌ها با خطای HTTP 500 شکست می‌خورند** (محرک هشدار نرخ خطا)
- `GET /api/slow` — ۱ تا ۳ ثانیه طول می‌کشد (محرک هشدار تأخیر)
- `GET /health` — بررسی سلامت

## شروع سریع

```bash
docker compose up --build -d
```

سپس این آدرس‌ها را باز کنید:

- **برنامهٔ وب:** http://localhost:5000
- **Prometheus:** http://localhost:9090 (برای اطمینان از جمع‌آوری: Status → Targets)
- **Alertmanager:** http://localhost:9093 (هشدارهای فعال و Silenceها)
- **Grafana:** http://localhost:3000 — ورود با `admin` / `admin`

داشبورد **«Web App Monitoring»** (۱۲ پنل: متریک‌ها، لاگ‌های زنده، پروبهای Uptime) به‌صورت خودکار Provision می‌شود — بدون نیاز به Import دستی.

## اسکریپت‌های کمکی

```powershell
.\validate.ps1                     # اعتبارسنجی پیکربندی Prometheus و Alertmanager با promtool/amtool قبل از استقرار
.\traffic.ps1                      # تولید ترافیک واقع‌گرایانه تا وقتی Ctrl+C بزنید
.\demo.ps1                         # دموی زندهٔ خرابی: توقف webapp ← فعال‌شدن WebAppDown ← بازیابی ← رفع هشدار
```

### دموی زندهٔ خرابی (demo.ps1)

با روشن بودن پشته، اسکریپت `.\demo.ps1` یک چرخهٔ کامل و قابل تکرار از خرابی را اجرا می‌کند و همهٔ مراحل را اندازه‌گیری می‌کند — این اعداد برای فصل ارزیابی پایان‌نامه بسیار مناسب‌اند:

1. **Preflight** — بررسی Docker، همهٔ کانتینرها و وضعیت جمع‌آوری Prometheus
2. **Baseline** — تولید ترافیک و اطمینان از فعال نبودن هیچ هشداری
3. **خرابی** — اجرای `docker compose stop webapp` ← تماشای افت `up{job="webapp"}` به صفر
4. **فعال‌شدن هشدار** — انتظار برای فعال‌شدن `WebAppDown` (فاصلهٔ ارزیابی ۵ ثانیه + شرط `for: 30s`) و تأیید دریافت آن در Alertmanager
5. **بازیابی** — اجرای `docker compose start webapp` ← برگشت جمع‌آوری و رفع خودکار هشدار

از `-Unattended` برای حذف مکث‌های بین فازها (مناسب ضبط ویدئو) و از `-TimeoutSeconds` برای دستگاه‌های کندتر استفاده کنید. اسکریپت در برابر Ctrl+C ایمن است: اگر وسط کار خارج شود، دستور لازم برای برگرداندن برنامه را به شما نشان می‌دهد.

نکتهٔ ویندوز: اگر اجرای اسکریپت‌ها با خطای Execution Policy مواجه شد، از این دستور استفاده کنید:

```powershell
powershell -ExecutionPolicy Bypass -File .\demo.ps1
```

## تولید ترافیک

در یک ترمینال دیگر:

```bash
while ($true) {
  Invoke-RestMethod http://localhost:5000/ | Out-Null
  Invoke-RestMethod http://localhost:5000/api/users | Out-Null
  try { Invoke-RestMethod http://localhost:5000/api/orders | Out-Null } catch {}
  try { Invoke-RestMethod http://localhost:5000/api/slow | Out-Null } catch {}
  Start-Sleep -Milliseconds 200
}
```

در کمتر از یک دقیقه، نرخ درخواست‌ها، صدک‌های تأخیر و نرخ خطا در داشبورد پر می‌شوند.

## هشدارها (prometheus/alerts.yml)

هر ۵ ثانیه توسط Prometheus ارزیابی و از طریق Alertmanager مسیریابی می‌شوند (http://localhost:9093):

| هشدار | شرط فعال‌شدن | شدت |
|---|---|---|
| `WebAppDown` | در دسترس نبودن مقصد Scrape به مدت ۳۰ ثانیه | critical |
| `HealthProbeFailing` | عدم دریافت HTTP 200 در پروب به مدت ۱ دقیقه | critical |
| `HighErrorRate` | بیش از ۵٪ پاسخ‌های 5xx در بازهٔ ۲ دقیقه | warning |
| `HighLatencyP95` | تأخیر p95 بیش از ۱ ثانیه به مدت ۲ دقیقه | warning |
| `ContainerUsingTooMuchCpu` | مصرف CPU بالای ۸۰٪ هر کانتینر به مدت ۵ دقیقه | warning |

فایل `alertmanager/alertmanager.yml` شامل درخت مسیریابی با گروه‌بندی، فاصلهٔ تکرار و یک قاعدهٔ Inhibit است (`WebAppDown` هشدارهای warning نویزی را بی‌صدا می‌کند). برای دریافت اعلان واقعی، بخش Webhook یا ایمیل را از حالت کامنت خارج کنید.

برای فعال‌کردن دستی هشدارها: برنامه را متوقف کنید (`docker compose stop webapp`) یا پیوسته `/api/slow` را صدا بزنید.

## مفاهیم کلیدی

- **Instrumentation در برابر Exposition:** برنامه خودش کد را ابزارپذیر می‌کند و متریک‌ها را از طریق `/metrics` عرضه می‌کند
- **مدل Pull:** Prometheus هدف‌ها را در بازه‌های زمانی خودش جمع‌آوری می‌کند، نه اینکه منتظر Push بماند
- **انواع متریک:** شمارنده‌ها (فقط صعودی)، هیستوگرام‌ها (توزیع تأخیر ← صدک‌ها)، گیج‌ها (مقدار لحظه‌ای)
- **PromQL:** تابع‌های `rate()` و `histogram_quantile()` و تجمیع با `sum by (...)`
- **خط لولهٔ هشدار:** قواعد ← Alertmanager ← مسیریابی/گروه‌بندی/Inhibition ← کانال‌های اعلان
- **تجمیع لاگ:** کشف سرویس Promtail از طریق Docker API ← Loki ← پنل لاگ Grafana (متریک و لاگ در یک‌جا)
- **پایش Blackbox/Synthetic:** بررسی endpointها از «دید کاربر» با ترفندهای Relabeling
- **متریک‌های چندلایه:** برنامه (webapp)، کانتینر (cAdvisor)، میزبان (node-exporter)
- **زیرساخت به‌عنوان پیکربندی:** DataSourceها و داشبوردهای Grafana از فایل Provision می‌شوند؛ همه‌چیز با docker-compose قابل بازتولید است
- **سیگنال‌های طلایی (Golden Signals):** ترافیک، خطا، تأخیر (+ اشباع از طریق node/cAdvisor)
- **اعتبارسنجی پیکربندی به‌عنوان عادت:** `validate.ps1` قبل از استقرار، بررسی‌های promtool/amtool را اجرا می‌کند

## ساختار پروژه

```
├── app/
│   ├── app.py               # برنامهٔ Flask با Instrumentation
│   ├── requirements.txt
│   └── Dockerfile
├── prometheus/
│   ├── prometheus.yml       # پیکربندی Scrape + هشداردهی + فایل قواعد
│   └── alerts.yml           # قواعد هشدار
├── alertmanager/
│   └── alertmanager.yml     # مسیریابی، گروه‌بندی، گیرنده‌ها
├── blackbox/
│   └── blackbox.yml         # ماژول پروب http_2xx
├── loki/
│   ├── loki-config.yml      # ذخیره‌سازی و اسکیمای Loki
│   └── promtail-config.yml  # جمع‌آوری لاگ با docker_sd
├── grafana/
│   ├── provisioning/
│   │   ├── datasources/prometheus.yml   # DataSourceهای Prometheus + Loki
│   │   └── dashboards/dashboards.yml
│   └── dashboards/webapp-dashboard.json
├── traffic.ps1              # مولد بار
├── validate.ps1             # اعتبارسنجی پیکربندی با promtool/amtool
└── docker-compose.yml       # ۹ سرویس روی یک شبکه
```

## پاک‌سازی

```bash
docker compose down -v
```
