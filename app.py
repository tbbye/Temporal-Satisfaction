# app.py
from __future__ import annotations

import csv
import io
import os
import re
import time
from typing import Any, Dict, List, Optional, Tuple

import numpy as np
import nltk
import requests
from flask import Flask, Response, jsonify, request
from flask_cors import CORS
from nltk.sentiment.vader import SentimentIntensityAnalyzer

# =============================================================
# APP SETUP
# =============================================================
app = Flask(__name__)

# CORS
# For better security, replace '*' with your frontend URL(s), for example:
# CORS(app, origins=["https://your-netlify-site.netlify.app"])
CORS(app)

# =============================================================
# NLTK SETUP
# =============================================================
def _ensure_nltk_resource(path: str, download_name: str) -> None:
    try:
        nltk.data.find(path)
    except LookupError:
        nltk.download(download_name, quiet=True)

# VADER lexicon
_ensure_nltk_resource("sentiment/vader_lexicon.zip", "vader_lexicon")
# Punkt tokenizer (sentence splitting)
_ensure_nltk_resource("tokenizers/punkt", "punkt")

analyzer = SentimentIntensityAnalyzer()

# =============================================================
# CONFIG
# =============================================================
POSITIVE_THRESHOLD = 0.2
NEGATIVE_THRESHOLD = -0.2

DEFAULT_REVIEW_CHUNK_SIZE = 20
STEAM_REVIEWS_PER_PAGE = 100

# Review collection pacing (avoid hammering Steam)
REQUEST_SLEEP_SECONDS = 0.5
APPDETAILS_ITEM_SLEEP_SECONDS = 0.05

# Cache behaviour (in-memory, best effort)
CACHE_TTL_SECONDS = 30 * 60       # 30 minutes
CACHE_MAX_ITEMS = 50             # keep last 50 analyses

# Appdetails cache
APPDETAILS_TTL_SECONDS = 24 * 60 * 60  # 24 hours
APPDETAILS_CACHE: Dict[str, Dict[str, Any]] = {}

# Hard caps (helps avoid timeouts / abuse)
MAX_REVIEW_COUNT = 5000
MIN_REVIEW_COUNT = 1

# =============================================================
# THEMATIC KEYWORDS
# =============================================================
LENGTH_KEYWORDS = [
    "hour", "hours", "length", "lengths", "lengthy", "short", "long",
    "time sink", "time investment", "time commitment",
    "seconds", "minute", "minutes", "hourly",
    "per day", "days", "weekly", "month", "months",
    "quarterly", "year", "years", "yearly", "annual",
    "session", "sessions", "playtime", "play time", "player time",
    "limited time",
    "runtime", "run time",
    "playthrough", "play-through",
    "game length", "story length",
    "beat in", "beaten in", "finished in", "finish in",
    "hours in",
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
    "timegate", "timegated",
]

VALUE_KEYWORDS = [
    # Time-relational value
    "replayable", "replayability", "content updates",
    "longevity", "shelf life",
    "lifespan", "life span", "roadmap", "road map", "season", "seasons", "seasonal",

    # Explicit time/price conjunctions
    "too short for the price",
    "worth the time", "not worth the time",
    "time well spent",
    "good use of time",
    "waste of time and money",
    "hours of content", "hours of gameplay",
    "per hour", "per-hour",

    # Respect for player time (implicit value)
    "respect my time", "respects my time", "respect your time", "respects your time",
    "respect the player's time", "respect the players' time", "respects the player's time",
    "respecting my time", "respecting your time",
    "waste my time", "wastes my time", "waste your time", "wastes your time",
    "waste of time", "total waste of time", "complete waste of time",
]

# =============================================================
# REGEX HELPERS
# =============================================================
def compile_keyword_pattern(keywords: List[str]) -> re.Pattern:
    parts: List[str] = []
    for k in keywords:
        k = (k or "").strip()
        if not k:
            continue
        if " " in k or "-" in k:
            # Phrase match
            parts.append(re.escape(k))
        else:
            # Single token word boundary match
            parts.append(r"\b" + re.escape(k) + r"\b")
    if not parts:
        # Match nothing
        return re.compile(r"(?!x)x")
    return re.compile("|".join(parts), re.IGNORECASE)

length_pattern = compile_keyword_pattern(LENGTH_KEYWORDS)
grind_pattern = compile_keyword_pattern(GRIND_KEYWORDS)
value_pattern = compile_keyword_pattern(VALUE_KEYWORDS)

ALL_PATTERNS: Dict[str, re.Pattern] = {
    "length": length_pattern,
    "grind": grind_pattern,
    "value": value_pattern,
}

# =============================================================
# CACHES
# =============================================================
TEMP_REVIEW_CACHE: Dict[str, Dict[str, Any]] = {}
CACHE_KEY_FORMAT = "{app_id}_{review_count}_{review_filter}_{language}"

def _now() -> float:
    return time.time()

def _purge_cache() -> None:
    now = _now()

    # Expire old entries
    expired_keys: List[str] = []
    for k, v in TEMP_REVIEW_CACHE.items():
        created_at = float(v.get("created_at", 0) or 0)
        if (now - created_at) > CACHE_TTL_SECONDS:
            expired_keys.append(k)
    for k in expired_keys:
        TEMP_REVIEW_CACHE.pop(k, None)

    # Enforce max size (remove oldest)
    if len(TEMP_REVIEW_CACHE) > CACHE_MAX_ITEMS:
        items = list(TEMP_REVIEW_CACHE.items())
        items.sort(key=lambda kv: float(kv[1].get("created_at", 0) or 0))
        to_remove = len(TEMP_REVIEW_CACHE) - CACHE_MAX_ITEMS
        for i in range(to_remove):
            TEMP_REVIEW_CACHE.pop(items[i][0], None)

def _purge_appdetails_cache() -> None:
    now = _now()
    expired: List[str] = []
    for appid, item in APPDETAILS_CACHE.items():
        created_at = float(item.get("created_at", 0) or 0)
        if (now - created_at) > APPDETAILS_TTL_SECONDS:
            expired.append(appid)
    for appid in expired:
        APPDETAILS_CACHE.pop(appid, None)

# =============================================================
# STEAM HELPERS
# =============================================================
def fetch_steam_appdetails(app_id: str) -> Optional[Dict[str, str]]:
    """
    Returns dict:
      {
        developer: str,
        publisher: str,
        header_image_url: str,
        release_date: str
      }
    or None
    """
    if not app_id:
        return None

    _purge_appdetails_cache()

    cached = APPDETAILS_CACHE.get(str(app_id))
    if isinstance(cached, dict):
        created_at = float(cached.get("created_at", 0) or 0)
        if (_now() - created_at) <= APPDETAILS_TTL_SECONDS:
            data = cached.get("data")
            return data if isinstance(data, dict) else None

    url = "https://store.steampowered.com/api/appdetails"
    params = {"appids": str(app_id), "l": "en", "cc": "US"}

    try:
        resp = requests.get(url, params=params, timeout=60)
        resp.raise_for_status()
        payload = resp.json()

        node = payload.get(str(app_id), {}) or {}
        if not node.get("success"):
            return None

        data = node.get("data", {}) or {}
        developers = data.get("developers") or []
        publishers = data.get("publishers") or []

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
            "release_date": release_date_str,
        }

        APPDETAILS_CACHE[str(app_id)] = {"created_at": _now(), "data": details}
        return details

    except Exception as e:
        print(f"[appdetails] Error for {app_id}: {e}")
        return None

def _safe_int(value: Any, default: int) -> int:
    try:
        return int(value)
    except Exception:
        return default

def _clamp(n: int, lo: int, hi: int) -> int:
    return max(lo, min(hi, n))

# =============================================================
# SENTIMENT (time-context only)
# =============================================================
def extract_time_sentiment_text(review_text: str) -> str:
    """Return only the sentence(s) that match any time-related theme pattern.
    If nothing matches, fall back to full review text.
    """
    review_text = review_text or ""
    if not review_text.strip():
        return ""

    try:
        sentences = nltk.sent_tokenize(review_text)
    except Exception:
        sentences = [review_text]

    matched: List[str] = []
    for s in sentences:
        for pattern in ALL_PATTERNS.values():
            if pattern.search(s):
                matched.append(s)
                break

    return " ".join(matched).strip() if matched else review_text

def get_review_sentiment_for_time_context(review_text: str) -> Tuple[str, float]:
    """Returns (label, compound_score)."""
    text = extract_time_sentiment_text(review_text)
    vs = analyzer.polarity_scores(text)
    compound = float(vs.get("compound", 0.0) or 0.0)

    if compound >= POSITIVE_THRESHOLD:
        return "Positive", compound
    if compound <= NEGATIVE_THRESHOLD:
        return "Negative", compound
    return "Neutral", compound

# =============================================================
# ANALYSIS HELPERS
# =============================================================
def analyze_theme_reviews(review_list: List[Dict[str, Any]]) -> Dict[str, Any]:
    pos = 0
    neg = 0
    neu = 0

    for r in review_list:
        label = r.get("sentiment_label")
        if label == "Positive":
            pos += 1
        elif label == "Negative":
            neg += 1
        else:
            neu += 1

    total = pos + neg + neu
    pn_total = pos + neg  # used for percent split like your original

    if pn_total > 0:
        pos_pct = (pos / pn_total) * 100
        neg_pct = (neg / pn_total) * 100
    else:
        pos_pct = 0.0
        neg_pct = 0.0

    return {
        "positive_count": pos,
        "negative_count": neg,
        "neutral_count": neu,
        "total_found": total,
        "total_analyzed_for_percent": pn_total,
        "positive_percent": round(pos_pct, 2),
        "negative_percent": round(neg_pct, 2),
    }

def calculate_playtime_distribution(all_reviews: List[Dict[str, Any]]) -> Dict[str, Any]:
    playtimes = [
        float(r.get("playtime_hours", 0.0) or 0.0)
        for r in all_reviews
        if float(r.get("playtime_hours", 0.0) or 0.0) > 0
    ]

    if not playtimes:
        return {
            "median_hours": 0.0,
            "percentile_25th": 0.0,
            "percentile_75th": 0.0,
            "interpretation": "Not enough data with recorded playtime to analyse distribution.",
            "histogram_buckets": [0] * 7,
            "histogram_bins_hours": ["<1", "1–5", "5–10", "10–20", "20–50", "50–100", "100+"],
        }

    arr = np.array(playtimes)
    median = float(np.median(arr))
    p25 = float(np.percentile(arr, 25))
    p75 = float(np.percentile(arr, 75))

    # bins: <1, 1–5, 5–10, 10–20, 20–50, 50–100, 100+
    bins = [0, 1, 5, 10, 20, 50, 100, float(arr.max()) + 1.0]
    hist, _ = np.histogram(arr, bins=bins)

    if p75 > 50 and median > 10:
        interp = "Players show high dedication, with the middle 50% spending over 10 hours."
    elif p75 > 10 and median < 5:
        interp = "Highly variable experience; many play briefly, but a significant core invests substantial time."
    else:
        interp = "The majority of players spend moderate time in the game."

    return {
        "median_hours": round(median, 2),
        "percentile_25th": round(p25, 2),
        "percentile_75th": round(p75, 2),
        "interpretation": interp,
        "histogram_buckets": [int(x) for x in hist.tolist()],
        "histogram_bins_hours": ["<1", "1–5", "5–10", "10–20", "20–50", "50–100", "100+"],
    }

def _tag_themes(review_text: str) -> List[str]:
    tags: List[str] = []
    for theme, pattern in ALL_PATTERNS.items():
        if pattern.search(review_text or ""):
            tags.append(theme)
    return tags

# =============================================================
# ROUTES
# =============================================================
@app.route("/health", methods=["GET"])
def health() -> Response:
    return jsonify({"status": "ok"}), 200

# -------------------------------------------------------------
# API ENDPOINT 1: Steam Review Analysis (/analyze)
# -------------------------------------------------------------
@app.route("/analyze", methods=["POST"])
def analyze_steam_reviews_api() -> Response:
    try:
        data = request.get_json(force=True) or {}
    except Exception as e:
        return jsonify({"error": f"Error parsing JSON body: {e}"}), 400

    app_id = str((data.get("app_id") or "")).strip()
    if not app_id:
        return jsonify({"error": "Missing 'app_id' in request body."}), 400

    review_count = _safe_int(data.get("review_count", 1000), 1000)
    review_count = _clamp(review_count, MIN_REVIEW_COUNT, MAX_REVIEW_COUNT)

    review_filter = str((data.get("filter") or "recent")).strip().lower()
    # Steam docs accept: recent, updated, all
    if review_filter not in {"recent", "updated", "all"}:
        review_filter = "recent"

    language = str((data.get("language") or "english")).strip().lower()
    if not language:
        language = "english"

    _purge_cache()

    cache_key = CACHE_KEY_FORMAT.format(
        app_id=app_id,
        review_count=review_count,
        review_filter=review_filter,
        language=language,
    )

    # Return cached result quickly if available and valid
    cached = TEMP_REVIEW_CACHE.get(cache_key)
    if isinstance(cached, dict):
        created_at = float(cached.get("created_at", 0) or 0)
        if (_now() - created_at) <= CACHE_TTL_SECONDS:
            cached_payload = cached.get("payload")
            if isinstance(cached_payload, dict):
                cached_payload["cache"] = {"hit": True, "age_seconds": int(_now() - created_at)}
                return jsonify(cached_payload), 200

    # Plan pages
    max_pages = (review_count // STEAM_REVIEWS_PER_PAGE) + (1 if review_count % STEAM_REVIEWS_PER_PAGE else 0)

    all_reviews_raw: List[Dict[str, Any]] = []
    api_url = f"https://store.steampowered.com/appreviews/{app_id}"

    params = {
        "json": 1,
        "language": language,
        "filter": review_filter,
        "num_per_page": STEAM_REVIEWS_PER_PAGE,
        "cursor": "*",
    }

    pages_fetched = 0
    while params.get("cursor") and pages_fetched < max_pages and len(all_reviews_raw) < review_count:
        pages_fetched += 1
        try:
            response = requests.get(api_url, params=params, timeout=60)
            response.raise_for_status()

            try:
                payload = response.json()
            except ValueError as e:
                print(f"[reviews] Non-JSON response, stopping: {e}")
                break

            if payload.get("success") != 1:
                break

            reviews_on_page = payload.get("reviews", []) or []
            if not reviews_on_page:
                break

            for review in reviews_on_page:
                if len(all_reviews_raw) >= review_count:
                    break

                author = review.get("author", {}) or {}
                playtime_minutes = author.get("playtime_at_review", author.get("playtime_forever", 0)) or 0
                review_text = review.get("review", "") or ""

                sentiment_label, sentiment_compound = get_review_sentiment_for_time_context(review_text)
                theme_tags = _tag_themes(review_text)

                all_reviews_raw.append(
                    {
                        "review_text": review_text,
                        "playtime_hours": round(float(playtime_minutes) / 60.0, 1),
                        "sentiment_label": sentiment_label,
                        "sentiment_compound": round(float(sentiment_compound), 4),
                        "theme_tags": theme_tags,
                    }
                )

            params["cursor"] = payload.get("cursor") or None
            time.sleep(REQUEST_SLEEP_SECONDS)

        except requests.RequestException as e:
            print(f"[reviews] Request error: {e}")
            break
        except Exception as e:
            print(f"[reviews] Unexpected error: {e}")
            break

    # Build themed collections
    themed_reviews: Dict[str, List[Dict[str, Any]]] = {"length": [], "grind": [], "value": []}
    all_themed_reviews: List[Dict[str, Any]] = []
    for r in all_reviews_raw:
        if r.get("theme_tags"):
            all_themed_reviews.append(r)
            for t in r["theme_tags"]:
                if t in themed_reviews:
                    themed_reviews[t].append(r)

    # Theme summaries
    length_analysis = analyze_theme_reviews(themed_reviews["length"])
    grind_analysis = analyze_theme_reviews(themed_reviews["grind"])
    value_analysis = analyze_theme_reviews(themed_reviews["value"])

    # Playtime distribution
    try:
        playtime_distribution = calculate_playtime_distribution(all_reviews_raw)
    except Exception as e:
        print(f"[playtime] Error: {e}")
        playtime_distribution = {
            "median_hours": 0.0,
            "percentile_25th": 0.0,
            "percentile_75th": 0.0,
            "interpretation": "Playtime distribution could not be calculated.",
            "histogram_buckets": [0] * 7,
            "histogram_bins_hours": ["<1", "1–5", "5–10", "10–20", "20–50", "50–100", "100+"],
        }

    # Optional appdetails for convenience (does not block if Steam appdetails fails)
    appdetails = fetch_steam_appdetails(app_id) or {
        "developer": "N/A",
        "publisher": "N/A",
        "header_image_url": "",
        "release_date": "",
    }

    payload_out: Dict[str, Any] = {
        "status": "success",
        "app_id": app_id,
        "review_count_requested": review_count,
        "review_count_used": review_count,
        "review_filter": review_filter,
        "language": language,
        "total_reviews_collected": len(all_reviews_raw),
        "total_themed_reviews": len(all_themed_reviews),

        "appdetails": appdetails,

        "thematic_scores": {
            "length": {
                "found": length_analysis["total_found"],
                "positive_percent": length_analysis["positive_percent"],
                "negative_percent": length_analysis["negative_percent"],
                "neutral_count": length_analysis["neutral_count"],
            },
            "grind": {
                "found": grind_analysis["total_found"],
                "positive_percent": grind_analysis["positive_percent"],
                "negative_percent": grind_analysis["negative_percent"],
                "neutral_count": grind_analysis["neutral_count"],
            },
            "value": {
                "found": value_analysis["total_found"],
                "positive_percent": value_analysis["positive_percent"],
                "negative_percent": value_analysis["negative_percent"],
                "neutral_count": value_analysis["neutral_count"],
            },
        },

        "playtime_distribution": playtime_distribution,

        # Transparent sentiment metadata + limitations (for your UI disclaimer)
        "sentiment_method": {
            "model": "NLTK VADER",
            "scope": "Sentiment is computed on time-relevant sentences when possible; otherwise the full review is used.",
            "thresholds": {
                "positive_compound_gte": POSITIVE_THRESHOLD,
                "negative_compound_lte": NEGATIVE_THRESHOLD,
            },
            "known_limitations": [
                "May misread sarcasm, memes, or mixed opinions.",
                "May not detect domain-specific meanings (e.g., grind as positive for some genres).",
                "Sentence extraction is keyword-based, so context can be missed.",
            ],
        },

        "cache": {"hit": False, "age_seconds": 0},
    }

    # Cache full payload + themed reviews for pagination/export
    TEMP_REVIEW_CACHE[cache_key] = {
        "created_at": _now(),
        "payload": payload_out,
        "reviews": all_themed_reviews,
    }

    return jsonify(payload_out), 200

# -------------------------------------------------------------
# API ENDPOINT 2: Game Name Search (/search)
# -------------------------------------------------------------
@app.route("/search", methods=["POST"])
def search_game() -> Response:
    try:
        data = request.get_json(force=True) or {}
    except Exception as e:
        return jsonify({"error": f"Error parsing JSON body: {e}"}), 400

    partial_name = str((data.get("name") or "")).strip()
    if not partial_name:
        return jsonify({"results": []}), 200

    _purge_appdetails_cache()

    search_api_url = "https://store.steampowered.com/api/storesearch/"
    params = {"term": partial_name, "l": "en", "cc": "US", "page": 1}

    try:
        response = requests.get(search_api_url, params=params, timeout=60)
        response.raise_for_status()
        store_data = response.json()

        matches: List[Dict[str, Any]] = []
        for item in (store_data.get("items", []) or []):
            game_id = item.get("id") or item.get("appid")
            name = item.get("name")

            if not game_id or not name:
                continue

            # Fallback image
            header_image = (
                item.get("header_image")
                or item.get("tiny_image")
                or (
                    "https://shared.cloudflare.steamstatic.com/"
                    f"store_item_assets/steam/apps/{game_id}/header.jpg"
                )
            )

            developer = "N/A"
            publisher = "N/A"
            release_date = ""

            details = fetch_steam_appdetails(str(game_id))
            if details:
                developer = details.get("developer") or "N/A"
                publisher = details.get("publisher") or "N/A"
                release_date = details.get("release_date") or ""
                header_from_details = details.get("header_image_url") or ""
                if header_from_details:
                    header_image = header_from_details

            time.sleep(APPDETAILS_ITEM_SLEEP_SECONDS)

            matches.append(
                {
                    "appid": str(game_id),
                    "name": name,
                    "header_image_url": header_image,
                    "release_date": release_date,
                    "developer": developer,
                    "publisher": publisher,
                }
            )

        return jsonify({"results": matches[:10]}), 200

    except Exception as e:
        print(f"[search] Error: {e}")
        return jsonify({"error": "Failed to connect to Steam Search API."}), 500

# -------------------------------------------------------------
# API ENDPOINT 3: Paginated Review Fetching (/reviews)
# -------------------------------------------------------------
@app.route("/reviews", methods=["GET"])
def get_paginated_reviews() -> Response:
    app_id = str((request.args.get("app_id") or "")).strip()
    offset = _safe_int(request.args.get("offset", 0), 0)
    limit = _safe_int(request.args.get("limit", DEFAULT_REVIEW_CHUNK_SIZE), DEFAULT_REVIEW_CHUNK_SIZE)
    total_count = _safe_int(request.args.get("total_count", 1000), 1000)

    review_filter = str((request.args.get("filter") or "recent")).strip().lower()
    if review_filter not in {"recent", "updated", "all"}:
        review_filter = "recent"

    language = str((request.args.get("language") or "english")).strip().lower()
    if not language:
        language = "english"

    if not app_id:
        return jsonify({"error": "Missing 'app_id' parameter."}), 400

    limit = _clamp(limit, 1, 200)
    offset = max(0, offset)

    cache_key = CACHE_KEY_FORMAT.format(
        app_id=app_id,
        review_count=_clamp(total_count, MIN_REVIEW_COUNT, MAX_REVIEW_COUNT),
        review_filter=review_filter,
        language=language,
    )

    cached = TEMP_REVIEW_CACHE.get(cache_key)
    if cached is None:
        return jsonify({"error": "Analysis data not found. Please run /analyze first."}), 404

    created_at = float(cached.get("created_at", 0) or 0)
    if (_now() - created_at) > CACHE_TTL_SECONDS:
        TEMP_REVIEW_CACHE.pop(cache_key, None)
        return jsonify({"error": "Analysis cache expired. Please run /analyze again."}), 404

    themed_reviews_list = cached.get("reviews", [])
    if not isinstance(themed_reviews_list, list):
        themed_reviews_list = []

    start_index = offset
    end_index = offset + limit
    reviews_page = themed_reviews_list[start_index:end_index]

    return jsonify(
        {
            "reviews": reviews_page,
            "total_available": len(themed_reviews_list),
            "offset": offset,
            "limit": limit,
        }
    ), 200

# -------------------------------------------------------------
# API ENDPOINT 4: Export Reviews to CSV (/export)
# -------------------------------------------------------------
@app.route("/export", methods=["GET"])
def export_reviews_csv() -> Response:
    app_id = str((request.args.get("app_id") or "")).strip()
    total_count = _safe_int(request.args.get("total_count", 1000), 1000)

    review_filter = str((request.args.get("filter") or "recent")).strip().lower()
    if review_filter not in {"recent", "updated", "all"}:
        review_filter = "recent"

    language = str((request.args.get("language") or "english")).strip().lower()
    if not language:
        language = "english"

    if not app_id:
        return jsonify({"error": "Missing 'app_id' parameter."}), 400

    cache_key = CACHE_KEY_FORMAT.format(
        app_id=app_id,
        review_count=_clamp(total_count, MIN_REVIEW_COUNT, MAX_REVIEW_COUNT),
        review_filter=review_filter,
        language=language,
    )

    cached = TEMP_REVIEW_CACHE.get(cache_key)
    if cached is None:
        return jsonify({"error": "Review data not found in cache. Please run /analyze first."}), 404

    created_at = float(cached.get("created_at", 0) or 0)
    if (_now() - created_at) > CACHE_TTL_SECONDS:
        TEMP_REVIEW_CACHE.pop(cache_key, None)
        return jsonify({"error": "Analysis cache expired. Please run /analyze again."}), 404

    all_themed_reviews = cached.get("reviews", [])
    if not isinstance(all_themed_reviews, list):
        all_themed_reviews = []

    output = io.StringIO()
    writer = csv.writer(output)
    writer.writerow(["Sentiment Label", "Sentiment Compound", "Playtime (Hours)", "Theme Tags", "Review Text"])

    for review in all_themed_reviews:
        sentiment = review.get("sentiment_label", "Neutral")
        compound = review.get("sentiment_compound", 0.0)
        playtime = review.get("playtime_hours", 0.0)
        tags = "|".join(review.get("theme_tags", []) or [])
        text = (review.get("review_text", "") or "").replace("\n", " ").strip()
        writer.writerow([sentiment, compound, playtime, tags, text])

    output.seek(0)

    file_name = f"steam_reviews_{app_id}_{total_count}_{review_filter}_{language}_themed.csv"
    return Response(
        output.getvalue(),
        mimetype="text/csv; charset=utf-8",
        headers={
            "Content-Disposition": f'attachment; filename="{file_name}"',
            "Cache-Control": "no-cache",
            "Access-Control-Expose-Headers": "Content-Disposition",
        },
    )

# =============================================================
# MAIN ENTRYPOINT
# =============================================================
if __name__ == "__main__":
    port = int(os.getenv("PORT", "5000"))
    debug = os.getenv("FLASK_DEBUG", "1") == "1"
    app.run(host="0.0.0.0", port=port, debug=debug)
