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
CORS(app)

# =============================================================
# NLTK SETUP
# =============================================================
def _ensure_nltk_resource(path: str, download_name: str) -> None:
    try:
        nltk.data.find(path)
    except LookupError:
        nltk.download(download_name, quiet=True)

_ensure_nltk_resource("sentiment/vader_lexicon.zip", "vader_lexicon")
_ensure_nltk_resource("tokenizers/punkt", "punkt")

analyzer = SentimentIntensityAnalyzer()

# =============================================================
# CONFIG
# =============================================================
POSITIVE_THRESHOLD = 0.2
NEGATIVE_THRESHOLD = -0.2

DEFAULT_REVIEW_CHUNK_SIZE = 20
STEAM_REVIEWS_PER_PAGE = 100

REQUEST_SLEEP_SECONDS = 0.6
APPDETAILS_ITEM_SLEEP_SECONDS = 0.05

CACHE_TTL_SECONDS = 30 * 60
CACHE_MAX_ITEMS = 50

APPDETAILS_TTL_SECONDS = 24 * 60 * 60
APPDETAILS_CACHE: Dict[str, Dict[str, Any]] = {}

MAX_REVIEW_COUNT = 5000
MIN_REVIEW_COUNT = 1

STEAM_TIMEOUT_SECONDS = 60
STEAM_RETRY_MAX = 4

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
    "replayable", "replayability", "content updates",
    "longevity", "shelf life",
    "lifespan", "life span", "roadmap", "road map", "season", "seasons", "seasonal",
    "too short for the price",
    "worth the time", "not worth the time",
    "time well spent",
    "good use of time",
    "waste of time and money",
    "hours of content", "hours of gameplay",
    "per hour", "per-hour",
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
            parts.append(re.escape(k))
        else:
            parts.append(r"\b" + re.escape(k) + r"\b")
    if not parts:
        return re.compile(r"(?!x)x")
    return re.compile("|".join(parts), re.IGNORECASE)

ALL_PATTERNS: Dict[str, re.Pattern] = {
    "length": compile_keyword_pattern(LENGTH_KEYWORDS),
    "grind": compile_keyword_pattern(GRIND_KEYWORDS),
    "value": compile_keyword_pattern(VALUE_KEYWORDS),
}

# =============================================================
# CACHES
# =============================================================
TEMP_REVIEW_CACHE: Dict[str, Dict[str, Any]] = {}

# IMPORTANT: support BOTH cache key formats (old + new)
CACHE_KEY_V1 = "{app_id}_{review_count}_{review_filter}_{language}"   # old
CACHE_KEY_V2 = "{app_id}_{review_filter}_{language}"                 # new

def _now() -> float:
    return time.time()

def _safe_int(value: Any, default: int) -> int:
    try:
        return int(value)
    except Exception:
        return default

def _clamp(n: int, lo: int, hi: int) -> int:
    return max(lo, min(hi, n))

def _purge_cache() -> None:
    now = _now()
    expired: List[str] = []
    for k, v in TEMP_REVIEW_CACHE.items():
        created_at = float(v.get("created_at", 0) or 0)
        if (now - created_at) > CACHE_TTL_SECONDS:
            expired.append(k)
    for k in expired:
        TEMP_REVIEW_CACHE.pop(k, None)

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

def _cursor_ok(c: Any) -> bool:
    if c is None:
        return False
    s = str(c).strip()
    return s != "" and s != "0"

def _truthy_flag(v: Any, default: bool = True) -> bool:
    if v is None:
        return default
    s = str(v).strip().lower()
    if s in {"0", "false", "no", "n"}:
        return False
    if s in {"1", "true", "yes", "y"}:
        return True
    return default

def _make_keys(app_id: str, review_filter: str, language: str, review_count: Optional[int]) -> Tuple[str, Optional[str]]:
    """
    Returns (v2_key, v1_key_or_none).
    """
    k2 = CACHE_KEY_V2.format(app_id=app_id, review_filter=review_filter, language=language)
    k1 = None
    if review_count is not None:
        k1 = CACHE_KEY_V1.format(
            app_id=app_id,
            review_count=int(review_count),
            review_filter=review_filter,
            language=language,
        )
    return k2, k1

def _get_cached_entry(
    app_id: str,
    review_filter: str,
    language: str,
    review_count_hint: Optional[int] = None
) -> Optional[Dict[str, Any]]:
    """
    Try v2 key first, then v1 (old) key if present.
    """
    k2, k1 = _make_keys(app_id, review_filter, language, review_count_hint)
    entry = TEMP_REVIEW_CACHE.get(k2)
    if isinstance(entry, dict):
        return entry
    if k1:
        entry = TEMP_REVIEW_CACHE.get(k1)
        if isinstance(entry, dict):
            return entry
    return None

def _store_entry_under_keys(
    entry: Dict[str, Any],
    app_id: str,
    review_filter: str,
    language: str,
    requested_count: int,
    effective_count: int
) -> None:
    """
    Store the SAME entry under multiple keys so old /reviews and new /reviews both work.
    """
    k2, k1_req = _make_keys(app_id, review_filter, language, requested_count)
    _,  k1_eff = _make_keys(app_id, review_filter, language, effective_count)

    # always store v2
    TEMP_REVIEW_CACHE[k2] = entry

    # also store old v1 keys (requested + effective)
    if k1_req:
        TEMP_REVIEW_CACHE[k1_req] = entry
    if k1_eff:
        TEMP_REVIEW_CACHE[k1_eff] = entry

# =============================================================
# STEAM HELPERS
# =============================================================
def fetch_steam_appdetails(app_id: str) -> Optional[Dict[str, str]]:
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
        resp = requests.get(url, params=params, timeout=STEAM_TIMEOUT_SECONDS)
        resp.raise_for_status()
        payload = resp.json()

        node = payload.get(str(app_id), {}) or {}
        if not node.get("success"):
            return None

        data = node.get("data", {}) or {}
        developers = data.get("developers") or []
        publishers = data.get("publishers") or []

        release_node = data.get("release_date") or {}
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

def _steam_get_with_retry(url: str, params: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    backoff = 1.0
    for attempt in range(1, STEAM_RETRY_MAX + 1):
        try:
            resp = requests.get(url, params=params, timeout=STEAM_TIMEOUT_SECONDS)

            if resp.status_code in (429, 503):
                print(f"[steam] {resp.status_code} throttle, attempt {attempt}/{STEAM_RETRY_MAX}, sleeping {backoff}s")
                time.sleep(backoff)
                backoff = min(backoff * 2.0, 12.0)
                continue

            resp.raise_for_status()
            try:
                return resp.json()
            except Exception as e:
                print(f"[steam] JSON parse error: {e}")
                return None

        except requests.RequestException as e:
            print(f"[steam] Request error attempt {attempt}/{STEAM_RETRY_MAX}: {e}")
            time.sleep(backoff)
            backoff = min(backoff * 2.0, 12.0)

    return None

def _safe_total_reviews_from_payload(payload: Dict[str, Any]) -> Optional[int]:
    try:
        qs = payload.get("query_summary", {}) or {}
        tr = qs.get("total_reviews", None)
        if tr is None:
            return None
        tr_i = _safe_int(tr, -1)
        if tr_i < 0:
            return None
        return tr_i
    except Exception:
        return None

def _tag_themes(review_text: str) -> List[str]:
    tags: List[str] = []
    t = review_text or ""
    for theme, pattern in ALL_PATTERNS.items():
        if pattern.search(t):
            tags.append(theme)
    return tags

def extract_time_sentiment_text(review_text: str) -> str:
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
    text = extract_time_sentiment_text(review_text)
    vs = analyzer.polarity_scores(text)
    compound = float(vs.get("compound", 0.0) or 0.0)

    if compound >= POSITIVE_THRESHOLD:
        return "Positive", compound
    if compound <= NEGATIVE_THRESHOLD:
        return "Negative", compound
    return "Neutral", compound

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
    pn_total = pos + neg

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

# =============================================================
# ROUTES
# =============================================================
@app.route("/health", methods=["GET"])
def health() -> Response:
    return jsonify({"status": "ok"}), 200

@app.route("/analyze", methods=["POST"])
def analyze_steam_reviews_api() -> Response:
    try:
        data = request.get_json(force=True) or {}
    except Exception as e:
        return jsonify({"error": f"Error parsing JSON body: {e}"}), 400

    app_id = str((data.get("app_id") or "")).strip()
    if not app_id:
        return jsonify({"error": "Missing 'app_id' in request body."}), 400

    review_count_req = _safe_int(data.get("review_count", 1000), 1000)
    review_count_req = _clamp(review_count_req, MIN_REVIEW_COUNT, MAX_REVIEW_COUNT)

    review_filter = str((data.get("filter") or "recent")).strip().lower()
    if review_filter not in {"recent", "updated", "all"}:
        review_filter = "recent"

    language = str((data.get("language") or "english")).strip().lower() or "english"

    _purge_cache()

    # Fetch existing entry (try both key styles)
    entry = _get_cached_entry(app_id, review_filter, language, review_count_hint=review_count_req)
    if isinstance(entry, dict):
        created_at = float(entry.get("created_at", 0) or 0)
        if (_now() - created_at) > CACHE_TTL_SECONDS:
            entry = None

    if not entry:
        entry = {
            "created_at": _now(),
            "cursor": "*",
            "all_reviews": [],
            "steam_total_reviews": None,
            "effective_target_count": review_count_req,
            # legacy storage expected by old /reviews + /export
            "payload": None,
            "reviews": [],
        }

    all_reviews: List[Dict[str, Any]] = entry.get("all_reviews", [])
    if not isinstance(all_reviews, list):
        all_reviews = []
        entry["all_reviews"] = all_reviews

    cursor = entry.get("cursor", "*") or "*"

    # Determine effective target if we know total
    steam_total = entry.get("steam_total_reviews", None)
    if isinstance(steam_total, int) and steam_total >= 0:
        target_count = _clamp(min(review_count_req, steam_total), MIN_REVIEW_COUNT, MAX_REVIEW_COUNT)
    else:
        target_count = review_count_req
    entry["effective_target_count"] = target_count

    need = max(0, target_count - len(all_reviews))

    if need > 0 and _cursor_ok(cursor):
        pages_needed = (need // STEAM_REVIEWS_PER_PAGE) + (1 if need % STEAM_REVIEWS_PER_PAGE else 0)

        api_url = f"https://store.steampowered.com/appreviews/{app_id}"
        params = {
            "json": 1,
            "language": language,
            "filter": review_filter,
            "num_per_page": STEAM_REVIEWS_PER_PAGE,
            "cursor": cursor,
        }

        pages_fetched = 0
        seen_cursors = set()
        first_page_seen = False

        while (
            pages_fetched < pages_needed
            and len(all_reviews) < target_count
            and _cursor_ok(params.get("cursor"))
        ):
            cur = str(params.get("cursor"))
            if cur in seen_cursors:
                break
            seen_cursors.add(cur)

            pages_fetched += 1

            payload = _steam_get_with_retry(api_url, params)
            if not payload or payload.get("success") != 1:
                break

            if not first_page_seen:
                first_page_seen = True
                total_reviews = _safe_total_reviews_from_payload(payload)
                if total_reviews is not None:
                    entry["steam_total_reviews"] = total_reviews
                    target_count = _clamp(min(review_count_req, total_reviews), MIN_REVIEW_COUNT, MAX_REVIEW_COUNT)
                    entry["effective_target_count"] = target_count

                    need = max(0, target_count - len(all_reviews))
                    pages_needed = (need // STEAM_REVIEWS_PER_PAGE) + (1 if need % STEAM_REVIEWS_PER_PAGE else 0)

            reviews_on_page = payload.get("reviews", []) or []
            if not reviews_on_page:
                # terminal condition even if cursor looks odd
                params["cursor"] = None
                break

            for review in reviews_on_page:
                if len(all_reviews) >= target_count:
                    break

                author = review.get("author", {}) or {}
                playtime_minutes = author.get("playtime_at_review", author.get("playtime_forever", 0)) or 0
                review_text = review.get("review", "") or ""

                sentiment_label, sentiment_compound = get_review_sentiment_for_time_context(review_text)
                theme_tags = _tag_themes(review_text)

                all_reviews.append(
                    {
                        "review_text": review_text,
                        "playtime_hours": round(float(playtime_minutes) / 60.0, 1),
                        "sentiment_label": sentiment_label,
                        "sentiment_compound": round(float(sentiment_compound), 4),
                        "theme_tags": theme_tags,
                    }
                )

            new_cursor = payload.get("cursor")
            params["cursor"] = new_cursor if _cursor_ok(new_cursor) else None
            cursor = params["cursor"]

            time.sleep(REQUEST_SLEEP_SECONDS)

        entry["cursor"] = cursor
        entry["created_at"] = _now()
        entry["all_reviews"] = all_reviews

        # if Steam didn't give totals, but we're terminal, infer total from collected
        if entry.get("steam_total_reviews", None) is None and not _cursor_ok(cursor):
            entry["steam_total_reviews"] = len(all_reviews)

    # Actual analysed count
    effective_target = _safe_int(entry.get("effective_target_count", review_count_req), review_count_req)
    analysed_count = min(effective_target, len(all_reviews))
    reviews_used = all_reviews[:analysed_count]

    themed_used = [r for r in reviews_used if (r.get("theme_tags") or [])]
    themed_by = {"length": [], "grind": [], "value": []}
    for r in themed_used:
        for t in (r.get("theme_tags") or []):
            if t in themed_by:
                themed_by[t].append(r)

    length_analysis = analyze_theme_reviews(themed_by["length"])
    grind_analysis = analyze_theme_reviews(themed_by["grind"])
    value_analysis = analyze_theme_reviews(themed_by["value"])

    playtime_distribution = calculate_playtime_distribution(reviews_used)

    appdetails = fetch_steam_appdetails(app_id) or {
        "developer": "N/A",
        "publisher": "N/A",
        "header_image_url": "",
        "release_date": "",
    }

    steam_total = entry.get("steam_total_reviews", None)

    note = None
    if isinstance(steam_total, int) and steam_total >= 0 and steam_total < review_count_req:
        note = f"Steam reports only {steam_total} total reviews for this game with the selected filter/language."

    if analysed_count == 0:
        note = (note + " " if note else "") + "No reviews were returned by Steam for this filter/language."
    elif len(themed_used) == 0:
        note = (note + " " if note else "") + f"No time-centric keywords were found in the {analysed_count} reviews analysed."

    # IMPORTANT COMPATIBILITY:
    # Many older frontends assume review_count_used == requested, even if fewer exist.
    # So we include BOTH:
    #   review_count_used -> requested (legacy)
    #   review_count_analyzed -> actual analysed
    payload_out: Dict[str, Any] = {
        "status": "success",
        "app_id": app_id,
        "review_filter": review_filter,
        "language": language,

        "review_count_requested": review_count_req,
        "review_count_used": review_count_req,          # legacy / UI compatibility
        "review_count_analyzed": analysed_count,        # the truth you can display
        "steam_total_reviews": steam_total,             # helps show "22 reviews total"

        "note": note,

        "cache_progress": {
            "cached_total_reviews": len(all_reviews),
            "cursor_is_none": entry.get("cursor") is None,
            "can_fetch_more": _cursor_ok(entry.get("cursor")) and len(all_reviews) < MAX_REVIEW_COUNT,
            "effective_target_count": effective_target,
        },

        "total_reviews_collected": analysed_count,
        "total_themed_reviews": len(themed_used),

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
    }

    # Store legacy fields expected by your older /reviews + /export code paths
    entry["payload"] = payload_out
    entry["reviews"] = themed_used  # legacy: themed reviews list for paging/export
    entry["created_at"] = _now()
    entry["all_reviews"] = all_reviews
    entry["effective_target_count"] = effective_target

    # Store entry under BOTH key formats (requested + effective)
    _store_entry_under_keys(
        entry=entry,
        app_id=app_id,
        review_filter=review_filter,
        language=language,
        requested_count=review_count_req,
        effective_count=analysed_count if analysed_count > 0 else review_count_req,
    )

    return jsonify(payload_out), 200

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
        response = requests.get(search_api_url, params=params, timeout=STEAM_TIMEOUT_SECONDS)
        response.raise_for_status()
        store_data = response.json()

        matches: List[Dict[str, Any]] = []
        for item in (store_data.get("items", []) or []):
            game_id = item.get("id") or item.get("appid")
            name = item.get("name")
            if not game_id or not name:
                continue

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

@app.route("/reviews", methods=["GET"])
def get_paginated_reviews() -> Response:
    app_id = str((request.args.get("app_id") or "")).strip()
    offset = _safe_int(request.args.get("offset", 0), 0)
    limit = _safe_int(request.args.get("limit", DEFAULT_REVIEW_CHUNK_SIZE), DEFAULT_REVIEW_CHUNK_SIZE)

    review_filter = str((request.args.get("filter") or "recent")).strip().lower()
    if review_filter not in {"recent", "updated", "all"}:
        review_filter = "recent"

    language = str((request.args.get("language") or "english")).strip().lower() or "english"

    total_count_raw = request.args.get("total_count", None)
    total_count_hint = _safe_int(total_count_raw, 0) if total_count_raw is not None else None

    # defaults: themed-only like old behaviour, but fallback so empty-themed games still show something
    themed_only = _truthy_flag(request.args.get("themed_only", "1"), default=True)
    fallback_to_all_if_none = _truthy_flag(request.args.get("fallback_to_all_if_none", "1"), default=True)

    if not app_id:
        return jsonify({"error": "Missing 'app_id' parameter."}), 400

    limit = _clamp(limit, 1, 200)
    offset = max(0, offset)

    _purge_cache()

    cached = _get_cached_entry(app_id, review_filter, language, review_count_hint=total_count_hint)
    if cached is None:
        return jsonify({"error": "Analysis data not found. Please run /analyze first."}), 404

    created_at = float(cached.get("created_at", 0) or 0)
    if (_now() - created_at) > CACHE_TTL_SECONDS:
        return jsonify({"error": "Analysis cache expired. Please run /analyze again."}), 404

    all_reviews = cached.get("all_reviews", [])
    if not isinstance(all_reviews, list):
        all_reviews = []

    effective_target = _safe_int(cached.get("effective_target_count", 1000), 1000)
    effective_target = _clamp(effective_target, MIN_REVIEW_COUNT, MAX_REVIEW_COUNT)

    if total_count_hint is None or total_count_hint <= 0:
        total_count = min(effective_target, len(all_reviews))
    else:
        total_count = _clamp(total_count_hint, MIN_REVIEW_COUNT, MAX_REVIEW_COUNT)
        total_count = min(total_count, len(all_reviews))

    reviews_used = all_reviews[:total_count]

    # legacy themed list (preferred if present)
    themed_legacy = cached.get("reviews", [])
    if not isinstance(themed_legacy, list):
        themed_legacy = []

    # recompute themed from current used slice (correct for total_count)
    themed = [r for r in reviews_used if (r.get("theme_tags") or [])]

    # Use themed list unless explicitly requesting all
    mode_returned = "themed" if themed_only else "all"
    items = themed if themed_only else reviews_used

    # key behaviour: if themed is empty, optionally fallback to all
    if themed_only and fallback_to_all_if_none and len(items) == 0 and len(reviews_used) > 0:
        items = reviews_used
        mode_returned = "all_fallback"

    start_index = offset
    end_index = offset + limit
    page = items[start_index:end_index]

    return jsonify(
        {
            "reviews": page,
            "mode_returned": mode_returned,
            "total_available": len(items),
            "themed_total_available": len(themed),
            "all_total_available": len(reviews_used),
            "offset": offset,
            "limit": limit,
            "total_count_used_for_paging": total_count,
            "effective_target_count": effective_target,
        }
    ), 200

@app.route("/export", methods=["GET"])
def export_reviews_csv() -> Response:
    app_id = str((request.args.get("app_id") or "")).strip()

    review_filter = str((request.args.get("filter") or "recent")).strip().lower()
    if review_filter not in {"recent", "updated", "all"}:
        review_filter = "recent"

    language = str((request.args.get("language") or "english")).strip().lower() or "english"

    total_count_raw = request.args.get("total_count", None)
    total_count_hint = _safe_int(total_count_raw, 0) if total_count_raw is not None else None

    themed_only = _truthy_flag(request.args.get("themed_only", "1"), default=True)
    fallback_to_all_if_none = _truthy_flag(request.args.get("fallback_to_all_if_none", "1"), default=True)

    if not app_id:
        return jsonify({"error": "Missing 'app_id' parameter."}), 400

    _purge_cache()

    cached = _get_cached_entry(app_id, review_filter, language, review_count_hint=total_count_hint)
    if cached is None:
        return jsonify({"error": "Review data not found in cache. Please run /analyze first."}), 404

    created_at = float(cached.get("created_at", 0) or 0)
    if (_now() - created_at) > CACHE_TTL_SECONDS:
        return jsonify({"error": "Analysis cache expired. Please run /analyze again."}), 404

    all_reviews = cached.get("all_reviews", [])
    if not isinstance(all_reviews, list):
        all_reviews = []

    effective_target = _safe_int(cached.get("effective_target_count", 1000), 1000)
    effective_target = _clamp(effective_target, MIN_REVIEW_COUNT, MAX_REVIEW_COUNT)

    if total_count_hint is None or total_count_hint <= 0:
        total_count = min(effective_target, len(all_reviews))
    else:
        total_count = _clamp(total_count_hint, MIN_REVIEW_COUNT, MAX_REVIEW_COUNT)
        total_count = min(total_count, len(all_reviews))

    reviews_used = all_reviews[:total_count]
    themed = [r for r in reviews_used if (r.get("theme_tags") or [])]

    rows = themed if themed_only else reviews_used
    mode_used = "themed" if themed_only else "all"
    if themed_only and fallback_to_all_if_none and len(rows) == 0 and len(reviews_used) > 0:
        rows = reviews_used
        mode_used = "all_fallback"

    output = io.StringIO()
    writer = csv.writer(output)
    writer.writerow(["Sentiment Label", "Sentiment Compound", "Playtime (Hours)", "Theme Tags", "Review Text"])

    for r in rows:
        sentiment = r.get("sentiment_label", "Neutral")
        compound = r.get("sentiment_compound", 0.0)
        playtime = r.get("playtime_hours", 0.0)
        tags = "|".join(r.get("theme_tags", []) or [])
        text = (r.get("review_text", "") or "").replace("\n", " ").strip()
        writer.writerow([sentiment, compound, playtime, tags, text])

    output.seek(0)
    file_name = f"steam_reviews_{app_id}_{total_count}_{review_filter}_{language}_{mode_used}.csv"

    return Response(
        output.getvalue(),
        mimetype="text/csv; charset=utf-8",
        headers={
            "Content-Disposition": f'attachment; filename="{file_name}"',
            "Cache-Control": "no-cache",
            "Access-Control-Expose-Headers": "Content-Disposition",
        },
    )

if __name__ == "__main__":
    port = int(os.getenv("PORT", "5000"))
    debug = os.getenv("FLASK_DEBUG", "1") == "1"
    app.run(host="0.0.0.0", port=port, debug=debug)
