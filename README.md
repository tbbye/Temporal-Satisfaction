# Temporal-Satisfaction

# STS Profiles (Steam Temporal Satisfaction Profiles)

A small research prototype that generates a quick, shareable snapshot of how players talk about **time in play** in Steam reviews – with a focus on **Length**, **Grind**, and **Value for time**.

STS Profiles is built to support exploratory insight for **players, researchers, and developers**. It is **not** an official rating system.

---

## What it does

Given a Steam AppID, the app:

- Pulls up to a target number of **recent Steam user reviews** (English by default)
- Scans reviews for time-centric keywords grouped into three themes:
  - **Length** (e.g., “short”, “hours”, “finish in…”)
  - **Grind** (e.g., “time-wasting”, “padding”, “time gated…”)
  - **Value** (e.g., “worth the time”, “respect my time”…)
- Estimates sentiment **only within time-relevant sentences** when possible (keyword-scoped), using **NLTK VADER**
- Produces an “STS Profile” including:
  - Thematic sentiment breakdown (Length / Grind / Value)
  - A playtime distribution summary from review author playtime
  - A themed review feed (with filtering + CSV export)
  - A shareable “poster” PNG export

---

## Live demo

- Web app: https://sts-profiles.netlify.app/
- Backend API (Render): https://temporal-satisfaction.onrender.com
- Source code: https://github.com/tbbye/Temporal-Satisfaction
- Related paper: https://dl.acm.org/doi/10.1145/3764687.3764693

---

## Not affiliated

STS Profiles is **not affiliated with, sponsored by, or endorsed by Valve or Steam**.  
Steam data © Valve Corporation. All trademarks are property of their respective owners.

---

## How it works

### Review collection
The backend calls Valve’s public review endpoint:

- `https://store.steampowered.com/appreviews/{appid}`

It fetches reviews in pages (`num_per_page=100`) using Steam’s cursor-based pagination with retries and backoff for throttling (e.g., `429` / `503`).

If Steam reports fewer total reviews than requested for the chosen filter/language, the analysis uses what’s available and returns a note.

### Time-centric filtering
Reviews are tagged as **Length / Grind / Value** using keyword + regex matching (word boundaries for single tokens, exact match for phrases/hyphenated terms).

By default, the UI shows **themed reviews only** (reviews that match at least one time theme).

### Sentiment
Sentiment is computed using **NLTK VADER**, scoped to **time-relevant sentences** (when possible). If sentence extraction fails or finds nothing, sentiment falls back to the full review text.

---

## Known limitations (important)

This is a research prototype and the output is indicative only:

- Automated sentiment can misread **sarcasm, jokes, memes, and mixed opinions**
- Keywords are imperfect and can miss context (or match false positives)
- “Grind” language can be **positive** in some genres/communities
- Steam content is dynamic – results depend on what’s been posted recently and what Steam returns for a given filter/language

Treat the STS Profile as a **starting point for inspection**, not a verdict.

---

## Tech stack

### Front end
- Flutter (Web)
- `url_launcher`, `http`, `file_saver`
- Exports: CSV (via backend link), PNG poster/screenshot (via Flutter canvas capture)

### Backend
- Python + Flask
- `requests`, `flask-cors`, `gunicorn`, `nltk`, `numpy`
- Sentiment: `nltk.sentiment.vader.SentimentIntensityAnalyzer`

---

## Repository structure (typical)

> Adjust these paths to match your repo.

/
backend/
app.py
requirements.txt
frontend/
lib/
screens/
search_screen.dart
analysis_screen.dart
pubspec.yaml
netlify.toml (optional)
README.md

yaml
Copy code

---

## API endpoints

Base URL (Render): `https://temporal-satisfaction.onrender.com`

### `GET /health`
Health check.

**Response**
```json
{ "status": "ok" }
POST /search
Search Steam by partial name and return up to 10 matches with metadata (developer/publisher/release date if available).

Body

json
Copy code
{ "name": "Inscryption" }
POST /analyze
Run (or extend) an analysis for an AppID.

Body

json
Copy code
{
  "app_id": "1091500",
  "review_count": 1000,
  "filter": "recent",
  "language": "english"
}
Notes:

review_count is clamped to 1..5000

filter supports: recent, updated, all

GET /reviews
Paged review feed (defaults to themed reviews only).

Example:

bash
Copy code
/reviews?app_id=1091500&offset=0&limit=20&total_count=1000
Optional flags:

themed_only=1 (default)

fallback_to_all_if_none=0 (default off)

GET /export
Export themed reviews (or all reviews if themed_only=0) as CSV.

Example:

arduino
Copy code
/export?app_id=1091500&total_count=1000
Local development
Backend (Flask)
Create and activate a virtual environment

Install dependencies

Run locally

bash
Copy code
cd backend
python -m venv .venv
source .venv/bin/activate  # Windows: .venv\Scripts\activate
pip install -r requirements.txt

export FLASK_DEBUG=1
export PORT=5000
python app.py
Front end (Flutter)
bash
Copy code
cd frontend
flutter pub get
flutter run -d chrome
The Flutter app uses:

Web: https://temporal-satisfaction.onrender.com

Local: http://127.0.0.1:5000

(See baseUrl in AnalysisScreen.)

Deployment
Backend (Render)
Render start command:

bash
Copy code
gunicorn app:app
(Your Render “Web Service” should point at the backend directory, with requirements.txt present.)

Front end (Netlify)
Build script used for Netlify:

bash
Copy code
#!/usr/bin/env bash
set -euo pipefail

echo "=== Installing Flutter SDK (if needed) ==="
if [ ! -d "$HOME/flutter" ]; then
  git clone --depth 1 -b stable https://github.com/flutter/flutter.git "$HOME/flutter"
fi

export PATH="$HOME/flutter/bin:$PATH"

echo "=== Flutter version info ==="
flutter --version

echo "=== Ensure stable channel & web enabled ==="
flutter channel stable
flutter upgrade --force
flutter config --enable-web
flutter precache --web

echo "=== Fetching Dart & Flutter packages ==="
flutter pub get

echo "=== Building Flutter web app (release) ==="
flutter build web --release

echo "=== Build complete. Web output at build/web ==="
Netlify publish directory:

build/web

Attribution
Code written with help from Gemini and ChatGPT.

Contact / feedback
Email: tom.sbyers93@gmail.com

Buy me a coffee: https://www.buymeacoffee.com/tbbye
