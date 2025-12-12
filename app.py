from flask import Flask, request, jsonify, Response
from flask_cors import CORS # <--- NEW IMPORT
import requests
import time
import json
import re
import numpy as np
import nltk
from nltk.sentiment.vader import SentimentIntensityAnalyzer
import io  # For handling CSV in memory

# --- GLOBAL INITIALIZATION ---
app = Flask(__name__)
# --- CORS CONFIGURATION (FIX FOR NETLIFY/BROWSER ACCESS) ---
# This allows requests from ANY origin ('*'). 
# For better security, replace '*' with your Netlify URL, e.g.,
# CORS(app, origins=["https://your-netlify-site.netlify.app"])
CORS(app) 
# -----------------------------------------------------------

# Download VADER lexicon data and initialize globally
try:
    nltk.data.find('sentiment/vader_lexicon.zip')
except LookupError:
    nltk.download('vader_lexicon', quiet=True)

analyzer = SentimentIntensityAnalyzer()

# --- CONFIGURATION (Settings) ---
POSITIVE_THRESHOLD = 0.2
NEGATIVE_THRESHOLD = -0.2
DEFAULT_REVIEW_CHUNK_SIZE = 20

# --- THEMATIC KEYWORDS (Centralized for the API) - VALUE LIST REVISED FOR TIME RELATIONSHIP ---
LENGTH_KEYWORDS = [
    "hour", "hours", "length", "lengths", "lengthy", "short", "long",
    "campaign", "time sink", "time investment", "time commitment",
    "second", "seconds", "minute", "minutes", "hourly",
    "day", "days", "weekly", "month", "months",
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
    "grind", "grindy", "farming", "farm", "repetitive", "repetition",
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
    "worth it", "value for money", "money well spent",
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

# Compile patterns for fast searching
length_pattern = re.compile('|'.join(re.escape(k) for k in LENGTH_KEYWORDS), re.IGNORECASE)
grind_pattern = re.compile('|'.join(re.escape(k) for k in GRIND_KEYWORDS), re.IGNORECASE)
value_pattern = re.compile('|'.join(re.escape(k) for k in VALUE_KEYWORDS), re.IGNORECASE)

# All patterns for general filtering
ALL_PATTERNS = {
    'length': length_pattern,
    'grind': grind_pattern,
    'value': value_pattern,
}

# --- CACHE SETUP (Temporary in-memory cache) ---
TEMP_REVIEW_CACHE = {}
CACHE_KEY_FORMAT = "{app_id}_{review_count}"


# --- HELPER FUNCTION: RUN SENTIMENT ANALYSIS ON A SINGLE REVIEW ---
def get_review_sentiment(review_text):
    """Calculates sentiment and returns a label."""
    vs = analyzer.polarity_scores(review_text)
    compound_score = vs['compound']

    if compound_score >= POSITIVE_THRESHOLD:
        return 'Positive'
    elif compound_score <= NEGATIVE_THRESHOLD:
        return 'Negative'
    else:
        return 'Neutral'


# --- HELPER FUNCTION: RUN SENTIMENT ANALYSIS ON A LIST OF REVIEWS ---
def analyze_theme_reviews(review_list):
    positive_count = 0
    negative_count = 0

    for review in review_list:
        if review.get('sentiment_label') == 'Positive':
            positive_count += 1
        elif review.get('sentiment_label') == 'Negative':
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
        "total_analyzed": total_analyzed
    }


# --- HELPER FUNCTION: CALCULATE PLAYTIME DISTRIBUTION ---
def calculate_playtime_distribution(all_reviews):
    playtimes = [r['playtime_hours'] for r in all_reviews if r['playtime_hours'] > 0]

    if not playtimes:
        return {
            "median_hours": 0.0,
            "percentile_25th": 0.0,
            "percentile_75th": 0.0,
            "interpretation": "Not enough data with recorded playtime to analyze distribution.",
            "histogram_buckets": [0.0] * 5
        }

    arr = np.array(playtimes)

    median = np.median(arr)
    p25 = np.percentile(arr, 25)
    p75 = np.percentile(arr, 75)

    # 0-1h, 1-5h, 5-20h, 20-50h, 50+h
    bins = [0, 1, 5, 20, 50, arr.max() + 1]
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
        "histogram_buckets": [round(float(h), 2) for h in hist.tolist()]
    }


# -------------------------------------------------------------
# API ENDPOINT 1: Steam Review Analysis (/analyze)
# -------------------------------------------------------------
@app.route('/analyze', methods=['POST'])
def analyze_steam_reviews_api():
    # 1. Get parameters from the request
    try:
        data = request.get_json(force=True) or {}
        APP_ID = data.get('app_id')
        review_count = int(data.get('review_count', 1000) or 1000)

        if not APP_ID:
            return jsonify({"error": "Missing 'app_id' in request body."}), 400

    except Exception as e:
        return jsonify({"error": f"Error parsing request: {e}"}), 400

    # 2. Determine collection parameters
    MAX_REVIEWS_TO_COLLECT = review_count
    max_pages_to_collect = MAX_REVIEWS_TO_COLLECT // 100
    if MAX_REVIEWS_TO_COLLECT % 100 != 0:
        max_pages_to_collect += 1

    all_reviews_raw = []
    API_URL = f"https://store.steampowered.com/appreviews/{APP_ID}"
    params = {
        'json': 1,
        'language': 'english',
        'filter': 'recent',
        'num_per_page': 100,
        'cursor': '*'
    }

    # --- Review Collection Loop ---
    page_count = 0
    while params['cursor'] and page_count < max_pages_to_collect:
        page_count += 1
        try:
            response = requests.get(API_URL, params=params, timeout=30)
            response.raise_for_status()

            try:
                data = response.json()
            except ValueError as e:
                print(f"Non-JSON response from Steam, stopping collection: {e}")
                break

            if data.get('success') != 1:
                # Steam returned a valid JSON but not a 'success' payload
                break

            reviews_on_page = data.get('reviews', [])
            if not reviews_on_page:
                break

            for review in reviews_on_page:
                if len(all_reviews_raw) >= MAX_REVIEWS_TO_COLLECT:
                    break

                author = review.get('author', {}) or {}
                playtime_minutes = author.get('playtime_at_review',
                                             author.get('playtime_forever', 0))

                review_text = review.get('review', "") or ""

                review_data = {
                    'review_text': review_text,
                    'playtime_hours': round(playtime_minutes / 60.0, 1),
                    'sentiment_label': get_review_sentiment(review_text),
                    'theme_tags': []
                }
                all_reviews_raw.append(review_data)

            params['cursor'] = data.get('cursor') or None
            if not params['cursor']:
                break

            # Small delay so we don't hammer Steam
            time.sleep(0.15)

        except requests.RequestException as e:
            # Network / HTTP error – stop trying, but keep what we have
            print(f"API Request Error while fetching reviews: {e}")
            break
        except Exception as e:
            # Anything unexpected during collection – stop, but don't 500
            print(f"Unexpected Error during collection: {e}")
            break

    # 3. Filtering and Thematic Tagging
    themed_reviews = {
        'length': [],
        'grind': [],
        'value': []
    }
    all_themed_reviews = []

    for review in all_reviews_raw:
        is_themed = False

        for theme, pattern in ALL_PATTERNS.items():
            if pattern.search(review['review_text']):
                review['theme_tags'].append(theme)
                themed_reviews[theme].append(review)
                is_themed = True

        if is_themed:
            all_themed_reviews.append(review)

    # 4. Thematic Sentiment Analysis & Playtime Distribution
    # (safe even if lists are empty)
    length_analysis = analyze_theme_reviews(themed_reviews['length'])
    grind_analysis = analyze_theme_reviews(themed_reviews['grind'])
    value_analysis = analyze_theme_reviews(themed_reviews['value'])

    try:
        playtime_distribution = calculate_playtime_distribution(all_reviews_raw)
    except Exception as e:
        print(f"Error calculating playtime distribution: {e}")
        playtime_distribution = {
            "median_hours": 0.0,
            "percentile_25th": 0.0,
            "percentile_75th": 0.0,
            "interpretation": "Playtime distribution could not be calculated.",
            "histogram_buckets": [0.0] * 5
        }

    # Save all_themed_reviews to the in-memory cache now
    cache_key = CACHE_KEY_FORMAT.format(app_id=APP_ID, review_count=review_count)
    TEMP_REVIEW_CACHE[cache_key] = all_themed_reviews

    # 5. Return the result (always 200 for analysis logic)
    return jsonify({
        "status": "success",
        "app_id": APP_ID,
        "review_count_used": review_count,          # keep as requested count for cache-key consistency
        "total_reviews_collected": len(all_reviews_raw),

        "thematic_scores": {
            "length": {
                "found": length_analysis['total_analyzed'],
                "positive_percent": length_analysis['positive_percent'],
                "negative_percent": length_analysis['negative_percent']
            },
            "grind": {
                "found": grind_analysis['total_analyzed'],
                "positive_percent": grind_analysis['positive_percent'],
                "negative_percent": grind_analysis['negative_percent']
            },
            "value": {
                "found": value_analysis['total_analyzed'],
                "positive_percent": value_analysis['positive_percent'],
                "negative_percent": value_analysis['negative_percent']
            }
        },

        "playtime_distribution": playtime_distribution,
        "total_themed_reviews": len(all_themed_reviews),

    }), 200


# -------------------------------------------------------------
# API ENDPOINT 2: Game Name Search (/search)
# -------------------------------------------------------------
@app.route('/search', methods=['POST'])
def search_game():
    try:
        data = request.get_json(force=True) or {}
    except Exception as e:
        return jsonify({"error": f"Error parsing JSON body: {e}"}), 400

    partial_name = data.get('name', '').strip()
    if not partial_name:
        return jsonify({"results": []}), 200

    SEARCH_API_URL = "https://store.steampowered.com/api/storesearch/"
    params = {
        'term': partial_name,
        'l': 'en',
        'cc': 'US',
        'page': 1
    }

    try:
        response = requests.get(SEARCH_API_URL, params=params, timeout=10)
        response.raise_for_status()

        store_data = response.json()

        matches = []
        for item in store_data.get('items', []):
            game_id = item.get('id') or item.get('appid')
            name = item.get('name')

            header_image = (
                item.get('header_image')
                or item.get('tiny_image')
                or (f"https://shared.cloudflare.steamstatic.com/"
                    f"store_item_assets/steam/apps/{game_id}/header.jpg")
            )

            if game_id and name:
                matches.append({
                    "appid": str(game_id),
                    "name": name,
                    "header_image_url": header_image,
                    "release_date": item.get('release_date', ''),
                    "developer": "N/A",
                    "publisher": "N/A",
                })

        matches = matches[:10]
        return jsonify({"results": matches}), 200

    except Exception as e:
        print(f"Error during Steam search API call: {e}")
        return jsonify({"error": "Failed to connect to Steam Search API."}), 500


# -------------------------------------------------------------
# API ENDPOINT 3: Paginated Review Fetching (/reviews)
# -------------------------------------------------------------
@app.route('/reviews', methods=['GET'])
def get_paginated_reviews():
    app_id = request.args.get('app_id')
    offset = int(request.args.get('offset', 0))
    limit = int(request.args.get('limit', DEFAULT_REVIEW_CHUNK_SIZE))
    total_count = int(request.args.get('total_count', 1000))

    if not app_id:
        return jsonify({"error": "Missing 'app_id' parameter."}), 400

    cache_key = CACHE_KEY_FORMAT.format(app_id=app_id, review_count=total_count)

    # Only treat "None" as missing; empty list is a valid "no themed reviews" case
    themed_reviews_list = TEMP_REVIEW_CACHE.get(cache_key)
    if themed_reviews_list is None:
        return jsonify({"error": "Analysis data not found. Please run /analyze first."}), 404

    start_index = offset
    end_index = offset + limit

    reviews_page = themed_reviews_list[start_index:end_index]
    total_available_themed = len(themed_reviews_list)

    return jsonify({
        "reviews": reviews_page,
        "total_available": total_available_themed,
        "offset": offset,
        "limit": limit
    }), 200


# -------------------------------------------------------------
# API ENDPOINT 4: Export Reviews to CSV (/export)
# -------------------------------------------------------------
@app.route('/export', methods=['GET'])
def export_reviews_csv():
    app_id = request.args.get('app_id')
    total_count = int(request.args.get('total_count', 1000))

    if not app_id:
        return jsonify({"error": "Missing 'app_id' parameter."}), 400

    cache_key = CACHE_KEY_FORMAT.format(app_id=app_id, review_count=total_count)

    all_themed_reviews = TEMP_REVIEW_CACHE.get(cache_key)
    # Again, only treat None as "no analysis"; empty list is fine
    if all_themed_reviews is None:
        return jsonify({"error": "Review data not found in cache. Please run /analyze first."}), 404

    output = io.StringIO()
    output.write("Sentiment Label,Playtime (Hours),Theme Tags,Review Text\n")

    for review in all_themed_reviews:
        sentiment = review.get('sentiment_label', 'neutral')
        playtime = review.get('playtime_hours', 0.0)
        tags = "|".join(review.get('theme_tags', []))
        text = review.get('review_text', "").replace('\n', ' ').replace(',', ';').strip()

        output.write(f"{sentiment},{playtime},{tags},{text}\n")

    output.seek(0)

    file_name = f"steam_reviews_{app_id}_{total_count}_themed.csv"
    return Response(
        output.getvalue(),
        mimetype="text/csv",
        headers={
            "Content-Disposition": f"attachment;filename={file_name}",
            "Cache-Control": "no-cache"
        }
    )


# -------------------------------------------------------------
# MAIN ENTRYPOINT
# -------------------------------------------------------------
if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=True)
