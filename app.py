from flask import Flask, request, jsonify
import requests
import time
import json
import re
import nltk
from nltk.sentiment.vader import SentimentIntensityAnalyzer

# --- GLOBAL VARIABLES ---
# This list is now DEPRECATED/EMPTY because we no longer try to cache the whole list.
STEAM_APP_LIST = []

# Initialize Flask app
app = Flask(__name__)

# -------------------------------------
# --- Load Steam App List (now a no-op) ---
def load_steam_app_list():
    # Intentionally empty – we no longer cache the full app list
    pass

# Call the function when the server starts up
load_steam_app_list()
# -------------------------------------


# Download VADER lexicon data and initialize globally
try:
    nltk.data.find('sentiment/vader_lexicon.zip')
except LookupError:
    nltk.download('vader_lexicon', quiet=True)

analyzer = SentimentIntensityAnalyzer()

# --- CONFIGURATION (Settings) ---
MAX_PAGES = 10
POSITIVE_THRESHOLD = 0.2
NEGATIVE_THRESHOLD = -0.2

# Time-Centric Keywords (Centralized for the API)
TIME_KEYWORDS = [
    "second", "seconds", "short playtime", "play time", "player time",
    "minute", "minutes", "long lifespan", "life span",
    "hour", "hours", "hourly", "length", "lengths", "lengthy", "limited time",
    "day", "days", "daily", "session", "sessions", "roadmap", "road map",
    "week", "weeks", "weekly", "season", "seasons", "seasonal",
    "month", "months", "monthly", "quarterly", "year", "years", "yearly",
    "annual", "replayable", "endless"
]
keyword_pattern = re.compile('|'.join(re.escape(k) for k in TIME_KEYWORDS), re.IGNORECASE)


# -------------------------------------------------------------
# API ENDPOINT 1: Steam Review Analysis (/analyze)
# -------------------------------------------------------------
@app.route('/analyze', methods=['POST'])
def analyze_steam_reviews_api():
    # 1. Get the App ID from the request
    try:
        data = request.get_json()
        APP_ID = data.get('app_id')

        if not APP_ID:
            return jsonify(
                {"error": "Missing 'app_id' in request body. Please provide a Steam App ID."}
            ), 400

    except Exception as e:
        return jsonify({"error": f"Error parsing request: {e}"}), 400

    # --- STEPS 1–3: Core Logic ---
    all_reviews_text = []
    API_URL = f"https://store.steampowered.com/appreviews/{APP_ID}"
    params = {
        'json': 1,
        'language': 'english',
        'filter': 'recent',
        'num_per_page': 100,
        'cursor': '*'
    }

    # Review Collection Loop
    page_count = 0
    while params['cursor'] and page_count < MAX_PAGES:
        page_count += 1
        try:
            response = requests.get(API_URL, params=params, timeout=10)
            if response.status_code == 200:
                data = response.json()
                if data.get('success') == 1:
                    reviews_on_page = data.get('reviews', [])
                    if not reviews_on_page:
                        break

                    for review in reviews_on_page:
                        all_reviews_text.append(review.get('review', ""))

                    params['cursor'] = data.get('cursor', None)
                    time.sleep(0.5)
                else:
                    break
            else:
                break
        except Exception:
            break

    # Filtering for time-centric language
    time_centric_reviews = []
    for review_text in all_reviews_text:
        if keyword_pattern.search(review_text):
            time_centric_reviews.append(review_text)

    # Sentiment Analysis
    positive_time_count = 0
    negative_time_count = 0

    for review in time_centric_reviews:
        vs = analyzer.polarity_scores(review)
        compound_score = vs['compound']

        if compound_score >= POSITIVE_THRESHOLD:
            positive_time_count += 1
        elif compound_score <= NEGATIVE_THRESHOLD:
            negative_time_count += 1

    total_analyzed = positive_time_count + negative_time_count

    if total_analyzed > 0:
        positive_percent = (positive_time_count / total_analyzed) * 100
        negative_percent = (negative_time_count / total_analyzed) * 100
    else:
        positive_percent = 0.0
        negative_percent = 0.0

    # 4. Return the result in a clean JSON format
    return jsonify({
        "status": "success",
        "app_id": APP_ID,
        "total_reviews_collected": len(all_reviews_text),
        "time_centric_reviews_found": len(time_centric_reviews),
        "positive_sentiment_percent": round(positive_percent, 2),
        "negative_sentiment_percent": round(negative_percent, 2)
    })


# -------------------------------------------------------------
# API ENDPOINT 2: Game Name Search (/search)
# -------------------------------------------------------------
@app.route('/search', methods=['POST'])
def search_game():
    # Parse the incoming JSON
    try:
        data = request.get_json(force=True) or {}
    except Exception as e:
        return jsonify({"error": f"Error parsing JSON body: {e}"}), 400

    partial_name = data.get('name', '').strip()

    # Empty name → empty list, not an error
    if not partial_name:
        return jsonify({"results": []}), 200

    # Use the Steam Store Search API
    SEARCH_API_URL = "https://store.steampowered.com/api/storesearch/"

    params = {
        'term': partial_name,  # e.g. "portal"
        'l': 'en',             # language
        'cc': 'US',            # country code
        'page': 1              # first page of results
    }

    try:
        response = requests.get(SEARCH_API_URL, params=params, timeout=10)
        response.raise_for_status()

        store_data = response.json()

        matches = []
        for item in store_data.get('items', []):
            # Steam storesearch generally returns 'id', not 'appid'
            game_id = item.get('id') or item.get('appid')
            name = item.get('name')

            if game_id and name:
                matches.append({
                    "appid": str(game_id),
                    "name": name
                })

        # Limit results to 10
        matches = matches[:10]

        return jsonify({"results": matches}), 200

    except Exception as e:
        print(f"Error during Steam search API call: {e}")
        return jsonify({"error": "Failed to connect to Steam Search API."}), 500


# -------------------------------------------------------------
# MAIN ENTRYPOINT (for local testing)
# -------------------------------------------------------------
if __name__ == '__main__':
    # debug=True for development – turn off in production
    app.run(host='0.0.0.0', port=5000, debug=True)
