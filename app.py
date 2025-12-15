from flask import Flask, request, jsonify, Response
from flask_cors import CORS
import requests
import time
import re
import io
import csv
import numpy as np
import nltk
from nltk.sentiment.vader import SentimentIntensityAnalyzer

# --- GLOBAL INITIALIZATION ---
app = Flask(__name__)

# --- CORS CONFIGURATION ---
# For better security, replace '*' with your Netlify URL:
# CORS(app, origins=["https://your-netlify-site.netlify.app"])
CORS(app)

# --- NLTK DATA SETUP ---
# VADER lexicon
try:
    nltk.data.find('sentiment/vader_lexicon.zip')
except LookupError:
    nltk.download('vader_lexicon', quiet=True)

# Punkt tokenizer (for sentence splitting)
try:
    nltk.data.find('tokenizers/punkt')
except LookupError:
    nltk.download('punkt', quiet=True)

analyzer = SentimentIntensityAnalyzer()

# --- CONFIGURATION (Settings) ---
POSITIVE_THRESHOLD = 0.2
NEGATIVE_THRESHOLD = -0.2
DEFAULT_REVIEW_CHUNK_SIZE = 20

# Cache behaviour
CACHE_TTL_SECONDS = 30 * 60  # 30 minutes
CACHE_MAX_ITEMS = 50         # keep last 50 analyses

# App details cache (developer/publisher/header image/release date)
APPDETAILS_TTL_SECONDS = 24 * 60 * 60  # 24 hours
APPDETAILS_CACHE = {}  # { "appid": {"created_at": ts, "data": {...}} }

# --- THEMATIC KEYWORDS ---
LENGTH_KEYWORDS = [
    "hour", "hours", "length", "lengths", "lengthy", "short", "long",
    "time sink", "time investment", "time commitment", "seconds", "minute", "minutes", "hourly",
    "per day", "days", "weekly", "month", "months",
    "quarterly", "year", "years", "yearly", "annual",
    "session", "sessions", "playtime", "play time", "player time",
    "limited time",
    "runtime", "run time",
    "playthrough", "play-through",
    "game length", "story length",
    "beat in", "beaten in", "finished in", "finish in",
    "hours in"
]

GRIND_KEYWORDS = [
    "grind", "grindy", "farming", "repetitive", "repetition",
    "burnout", "dailies", "daily", "chore", "time waste",
    "waste of time", "time waster", "time-waster",
    "time wasting", "time-wasting",
    "time-consuming", "time consuming",
    "busywork", "padding", "filler",
    "tedious", "tedium", "tedius",
    "grindfest", "grind fest", "mindless grind",
    "time gate", "time gated", "time-gated",
    "timegate", "timegated"
]

VALUE_KEYWORDS = [
    # Time-Relational Value
    "replayable", "replayability", "content updates",
    "longevity", "shelf life",
    "lifespan", "life span", "roadmap", "road map", "season", "seasons", "seasonal",

    # Explicit Time/Price Conjunctions
    "too short for the price",
    "worth the time", "not worth the time",
    "time well spent",
    "good use of time",
    "waste of time and money",
    "hours of content", "hours of gameplay",
    "per hour", "per-hour",

    # Respect for Player Time (Implicit Value)
    "respect my time", "respects my time", "respect your time", "respects your time",
    "respect the player's time", "respect the players' time", "respects the player's time",
    "respecting my time", "respecting your time",
    "waste my time", "wastes my time", "waste your time", "wastes your time",
    "waste of time", "total waste of time", "complete waste of time",
]

# --- REGEX HELPERS (word boundaries for single words) ---
def compile_keyword_pattern(keywords):
    parts = []
    for k in keywords:
        k = (k or "").strip()
        if not k:
            continue
        if " " in k or "-" in k:
            # phrase – match as-is
            parts.append(re.escape(k))
        else:
            # single token – word boundary match to reduce false positives
            parts.append(r"\b" + re.escape(k) + r"\b")
    return re.compile("|".join(parts), re.IGNORECASE)

length_pattern = compile_keyword_pattern(LENGTH_KEYWORDS)
grind_pattern = compile_keyword_pattern(GRIND_KEYWORDS)
value_pattern = compile_keyword_pattern(VALUE_KEYWORDS)

ALL_PATTERNS = {
    "length": length_pattern,
    "grind": grind_pattern,
    "value": value_pattern,
}

# --- CACHE SETUP (Temporary in-memory cache) ---
TEMP_REVIEW_CACHE = {}
CACHE_KEY_FORMAT = "{app_id}_{review_count}"

def _purge_cache():
    """Remove expired items and enforce max cache size."""
    now = time.time()

    # Expire old entries
    expired = []
    for k, v in TEMP_REVIEW_CACHE.items():
        if isinstance(v, dict):
            created_at = v.get("created_at", 0)
            if (now - created_at) > CACHE_TTL_SECONDS:
                expired.append(k)
    for k in expired:
        TEMP_REVIEW_CACHE.pop(k, None)

    # Enforce max size (remove oldest)
    if len(TEMP_REVIEW_CACHE) > CACHE_MAX_ITEMS:
        items = list(TEMP_REVIEW_CACHE.items())
        items.sort(key=lambda kv: kv[1].get("created_at", 0) if isinstance(kv[1], dict) else 0)
        to_remove = len(TEMP_REVIEW_CACHE) - CACHE_MAX_ITEMS
        for i in range(to_remove):
            TEMP_REVIEW_CACHE.pop(items[i][0], None)

def _purge_appdetails_cache():
    now = time.time()
    expired = []
    for appid, item in APPDETAILS_CACHE.items():
        created_at = item.get("created_at", 0)
        if (now - created_at) > APPDETAILS_TTL_SECONDS:
            expired.append(appid)
    for appid in expired:
        APPDETAILS_CACHE.pop(appid, None)

# Fetch developer/publisher/header_image/release_date via Steam appdetails
def fetch_steam_appdetails(app_id: str):
    """
    Returns dict:
      {
        developer: str,
        publisher: str,
        header_image_url: str,
        release_date: str
      }
    or None.
    """
    if not app_id:
        return None

    cached = APPDETAILS_CACHE.get(str(app_id))
    if isinstance(cached, dict):
        created_at = cached.get("created_at", 0)
        if (time.time() - created_at) <= APPDETAILS_TTL_SECONDS:
            return cached.get("data")

    url = "https://store.steampowered.com/api/appdetails"
    params = {
        "appids": str(app_id),
        "l": "en",
        "cc": "US",
    }

    try:
        resp = requests.get(url, params=params, timeout=30)
        resp.raise_for_status()
        payload = resp.json()

        node = payload.get(str(app_id), {}) or {}
        if not node.get("success"):
            return None

        data = node.get("data", {}) or {}

        developers = data.get("developers") or []
        publishers = data.get("publishers") or []

        # NEW: release date (Steam returns dict like {"coming_soon": False, "date": "15 Nov, 2021"})
        release_node = data.get("release_date") or {}
        release_date_str = ""
        if isinstance(release_node, dict):
            release_date_str = release_node.get("date") or ""
        else:
            release_date_str = str(release_node)

        details = {
            "developer": developers[0] if developers else "N/A",
            "publisher": publishers[0] if publishers else "N/A",
            "header_image_url": data.get("header_image") or "",
            "release_date": release_date_str,  # <- NEW
        }

        APPDETAILS_CACHE[str(app_id)] = {
            "created_at": time.time(),
            "data": details,
        }
        return details

    except Exception as e:
        print(f"Error fetching appdetails for {app_id}: {e}")
        return None

# --- SENTIMENT (time-context only) ---
def extract_time_sentiment_text(review_text: str) -> str:
    """Return only the sentence(s) that match any time-related theme pattern."""
    review_text = review_text or ""
    try:
        sentences = nltk.sent_tokenize(review_text)
    except Exception:
        sentences = [review_text]

    matched = []
    for s in sentences:
        for _, pattern in ALL_PATTERNS.items():
            if pattern.search(s):
                matched.append(s)
                break

    return " ".join(matched).strip() if matched else review_text

def get_review_sentiment_for_time_context(review_text: str) -> str:
    text = extract_time_sentiment_text(review_text)
    vs = analyzer.polarity_scores(text)
    compound = vs.get("compound", 0.0)

    if compound >= POSITIVE_THRESHOLD:
        return "Positive"
    elif compound <= NEGATIVE_THRESHOLD:
        return "Negative"
    else:
        return "Neutral"

# --- HELPER: THEME SENTIMENT SUMMARY ---
def analyze_theme_reviews(review_list):
    positive_count = 0
    negative_count = 0

    for review in review_list:
        if review.get("sentiment_label") == "Positive":
            positive_count += 1
        elif review.get("sentiment_label") == "Negative":
            negative_count += 1

    total_analyzed = positive_count + negative_count

    if total_analyzed > 0:
        positive_percent = (positive_count / total_analyzed) * 100
        negative_percent = (negative_count / total_analyzed) * 100
    else:
        positive_percent = 0.0
        negative_percent = 0.0

    return {
        "positive_count": positive_count,
        "negative_count": negative_count,
        "positive_percent": round(positive_percent, 2),
        "negative_percent": round(negative_percent, 2),
        "total_analyzed": total_analyzed,
    }

# --- HELPER: PLAYTIME DISTRIBUTION ---
def calculate_playtime_distribution(all_reviews):
    playtimes = [r.get("playtime_hours", 0.0) for r in all_reviews if (r.get("playtime_hours", 0.0) or 0.0) > 0]

    if not playtimes:
        return {
            "median_hours": 0.0,
            "percentile_25th": 0.0,
            "percentile_75th": 0.0,
            "interpretation": "Not enough data with recorded playtime to analyse distribution.",
            "histogram_buckets": [0.0] * 7
        }

    arr = np.array(playtimes)

    median = np.median(arr)
    p25 = np.percentile(arr, 25)
    p75 = np.percentile(arr, 75)

    # bins: <1, 1–5, 5–10, 10–20, 20–50, 50–100, 100+
    bins = [0, 1, 5, 10, 20, 50, 100, arr.max() + 1]
    hist, _ = np.histogram(arr, bins=bins)

    if p75 > 50 and median > 10:
        interp = "Players show high dedication, with the middle 50% spending over 10 hours."
    elif p75 > 10 and median < 5:
        interp = "Highly variable experience; many play briefly, but a significant core invests substantial time."
    else:
        interp = "The majority of players spend moderate time in the game."

    return {
        "median_hours": round(float(median), 2),
        "percentile_25th": round(float(p25), 2),
        "percentile_75th": round(float(p75), 2),
        "interpretation": interp,
        "histogram_buckets": [int(x) for x in hist.tolist()]
    }

# -------------------------------------------------------------
# API ENDPOINT 1: Steam Review Analysis (/analyze)
# -------------------------------------------------------------
@app.route("/analyze", methods=["POST"])
def analyze_steam_reviews_api():
    try:
        data = request.get_json(force=True) or {}
        app_id = data.get("app_id")
        review_count = int(data.get("review_count", 1000) or 1000)

        if not app_id:
            return jsonify({"error": "Missing 'app_id' in request body."}), 400
    except Exception as e:
        return jsonify({"error": f"Error parsing request: {e}"}), 400

    _purge_cache()

    max_reviews_to_collect = review_count
    max_pages_to_collect = max_reviews_to_collect // 100
    if max_reviews_to_collect % 100 != 0:
        max_pages_to_collect += 1

    all_reviews_raw = []
    api_url = f"https://store.steampowered.com/appreviews/{app_id}"
    params = {
        "json": 1,
        "language": "english",
        "filter": "recent",
        "num_per_page": 100,
        "cursor": "*",
    }

    page_count = 0
    while params["cursor"] and page_count < max_pages_to_collect:
        page_count += 1
        try:
            response = requests.get(api_url, params=params, timeout=60)
            response.raise_for_status()

            try:
                payload = response.json()
            except ValueError as e:
                print(f"Non-JSON response from Steam, stopping collection: {e}")
                break

            if payload.get("success") != 1:
                break

            reviews_on_page = payload.get("reviews", [])
            if not reviews_on_page:
                break

            for review in reviews_on_page:
                if len(all_reviews_raw) >= max_reviews_to_collect:
                    break

                author = review.get("author", {}) or {}
                playtime_minutes = author.get("playtime_at_review", author.get("playtime_forever", 0)) or 0

                review_text = review.get("review", "") or ""

                review_data = {
                    "review_text": review_text,
                    "playtime_hours": round(playtime_minutes / 60.0, 1),
                    "sentiment_label": get_review_sentiment_for_time_context(review_text),
                    "theme_tags": [],
                }
                all_reviews_raw.append(review_data)

            params["cursor"] = payload.get("cursor") or None
            if not params["cursor"]:
                break

            time.sleep(0.5)

        except requests.RequestException as e:
            print(f"API Request Error while fetching reviews: {e}")
            break
        except Exception as e:
            print(f"Unexpected Error during collection: {e}")
            break

    # Filtering and Thematic Tagging
    themed_reviews = {"length": [], "grind": [], "value": []}
    all_themed_reviews = []

    for review in all_reviews_raw:
        is_themed = False
        for theme, pattern in ALL_PATTERNS.items():
            if pattern.search(review["review_text"]):
                review["theme_tags"].append(theme)
                themed_reviews[theme].append(review)
                is_themed = True
        if is_themed:
            all_themed_reviews.append(review)

    # Theme sentiment analysis + playtime distribution
    length_analysis = analyze_theme_reviews(themed_reviews["length"])
    grind_analysis = analyze_theme_reviews(themed_reviews["grind"])
    value_analysis = analyze_theme_reviews(themed_reviews["value"])

    try:
        playtime_distribution = calculate_playtime_distribution(all_reviews_raw)
    except Exception as e:
        print(f"Error calculating playtime distribution: {e}")
        playtime_distribution = {
            "median_hours": 0.0,
            "percentile_25th": 0.0,
            "percentile_75th": 0.0,
            "interpretation": "Playtime distribution could not be calculated.",
            "histogram_buckets": [0.0] * 7
        }

    # Cache themed reviews with TTL metadata
    cache_key = CACHE_KEY_FORMAT.format(app_id=app_id, review_count=review_count)
    TEMP_REVIEW_CACHE[cache_key] = {
        "created_at": time.time(),
        "reviews": all_themed_reviews,
    }

    return jsonify({
        "status": "success",
        "app_id": app_id,
        "review_count_used": review_count,
        "total_reviews_collected": len(all_reviews_raw),

        "thematic_scores": {
            "length": {
                "found": length_analysis["total_analyzed"],
                "positive_percent": length_analysis["positive_percent"],
                "negative_percent": length_analysis["negative_percent"],
            },
            "grind": {
                "found": grind_analysis["total_analyzed"],
                "positive_percent": grind_analysis["positive_percent"],
                "negative_percent": grind_analysis["negative_percent"],
            },
            "value": {
                "found": value_analysis["total_analyzed"],
                "positive_percent": value_analysis["positive_percent"],
                "negative_percent": value_analysis["negative_percent"],
            },
        },

        "playtime_distribution": playtime_distribution,
        "total_themed_reviews": len(all_themed_reviews),
    }), 200

# -------------------------------------------------------------
# API ENDPOINT 2: Game Name Search (/search)
# -------------------------------------------------------------
@app.route("/search", methods=["POST"])
def search_game():
    try:
        data = request.get_json(force=True) or {}
    except Exception as e:
        return jsonify({"error": f"Error parsing JSON body: {e}"}), 400

    partial_name = (data.get("name", "") or "").strip()
    if not partial_name:
        return jsonify({"results": []}), 200

    _purge_appdetails_cache()

    search_api_url = "https://store.steampowered.com/api/storesearch/"
    params = {
        "term": partial_name,
        "l": "en",
        "cc": "US",
        "page": 1,
    }

    try:
        response = requests.get(search_api_url, params=params, timeout=30)
        response.raise_for_status()
        store_data = response.json()

        matches = []
        for item in store_data.get("items", []):
            game_id = item.get("id") or item.get("appid")
            name = item.get("name")

            # Default (fallback) image
            header_image = (
                item.get("header_image")
                or item.get("tiny_image")
                or (f"https://shared.cloudflare.steamstatic.com/"
                    f"store_item_assets/steam/apps/{game_id}/header.jpg")
            )

            developer = "N/A"
            publisher = "N/A"
            release_date = ""  # <- NEW

            # Fetch developer/publisher/header image/release date from appdetails
            if game_id:
                details = fetch_steam_appdetails(str(game_id))
                if details:
                    developer = details.get("developer") or "N/A"
                    publisher = details.get("publisher") or "N/A"

                    header_from_details = details.get("header_image_url") or ""
                    if header_from_details:
                        header_image = header_from_details

                    release_date = details.get("release_date") or ""  # <- NEW

                # small delay to avoid hammering Steam if you get many items
                time.sleep(0.05)

            if game_id and name:
                matches.append({
                    "appid": str(game_id),
                    "name": name,
                    "header_image_url": header_image,
                    "release_date": release_date,  # <- NEW (reliable now)
                    "developer": developer,
                    "publisher": publisher,
                })

        return jsonify({"results": matches[:10]}), 200

    except Exception as e:
        print(f"Error during Steam search API call: {e}")
        return jsonify({"error": "Failed to connect to Steam Search API."}), 500

# -------------------------------------------------------------
# API ENDPOINT 3: Paginated Review Fetching (/reviews)
# -------------------------------------------------------------
@app.route("/reviews", methods=["GET"])
def get_paginated_reviews():
    app_id = request.args.get("app_id")
    offset = int(request.args.get("offset", 0))
    limit = int(request.args.get("limit", DEFAULT_REVIEW_CHUNK_SIZE))
    total_count = int(request.args.get("total_count", 1000))

    if not app_id:
        return jsonify({"error": "Missing 'app_id' parameter."}), 400

    cache_key = CACHE_KEY_FORMAT.format(app_id=app_id, review_count=total_count)
    cached = TEMP_REVIEW_CACHE.get(cache_key)

    if cached is None:
        return jsonify({"error": "Analysis data not found. Please run /analyze first."}), 404

    # TTL check (in case purge hasn’t run yet)
    if isinstance(cached, dict):
        created_at = cached.get("created_at", 0)
        if (time.time() - created_at) > CACHE_TTL_SECONDS:
            TEMP_REVIEW_CACHE.pop(cache_key, None)
            return jsonify({"error": "Analysis cache expired. Please run /analyze again."}), 404
        themed_reviews_list = cached.get("reviews", [])
    else:
        themed_reviews_list = cached

    start_index = offset
    end_index = offset + limit
    reviews_page = themed_reviews_list[start_index:end_index]

    return jsonify({
        "reviews": reviews_page,
        "total_available": len(themed_reviews_list),
        "offset": offset,
        "limit": limit,
    }), 200

# -------------------------------------------------------------
# API ENDPOINT 4: Export Reviews to CSV (/export)
# -------------------------------------------------------------
@app.route("/export", methods=["GET"])
def export_reviews_csv():
    app_id = request.args.get("app_id")
    total_count = int(request.args.get("total_count", 1000))

    if not app_id:
        return jsonify({"error": "Missing 'app_id' parameter."}), 400

    cache_key = CACHE_KEY_FORMAT.format(app_id=app_id, review_count=total_count)
    cached = TEMP_REVIEW_CACHE.get(cache_key)

    if cached is None:
        return jsonify({"error": "Review data not found in cache. Please run /analyze first."}), 404

    # TTL check
    if isinstance(cached, dict):
        created_at = cached.get("created_at", 0)
        if (time.time() - created_at) > CACHE_TTL_SECONDS:
            TEMP_REVIEW_CACHE.pop(cache_key, None)
            return jsonify({"error": "Analysis cache expired. Please run /analyze again."}), 404
        all_themed_reviews = cached.get("reviews", [])
    else:
        all_themed_reviews = cached

    output = io.StringIO()
    writer = csv.writer(output)
    writer.writerow(["Sentiment Label", "Playtime (Hours)", "Theme Tags", "Review Text"])

    for review in all_themed_reviews:
        sentiment = review.get("sentiment_label", "Neutral")
        playtime = review.get("playtime_hours", 0.0)
        tags = "|".join(review.get("theme_tags", []))
        text = (review.get("review_text", "") or "").replace("\n", " ").strip()
        writer.writerow([sentiment, playtime, tags, text])

    output.seek(0)

    file_name = f"steam_reviews_{app_id}_{total_count}_themed.csv"
    return Response(
        output.getvalue(),
        mimetype="text/csv; charset=utf-8",
        headers={
            "Content-Disposition": f'attachment; filename="{file_name}"',
            "Cache-Control": "no-cache",
            "Access-Control-Expose-Headers": "Content-Disposition",
        },
    )

# -------------------------------------------------------------
# MAIN ENTRYPOINT
# -------------------------------------------------------------
if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=True)
