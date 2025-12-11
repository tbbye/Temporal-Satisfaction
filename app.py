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
# --- NEW FUNCTION: Load Steam App List ---
# This function is now empty to bypass the slow and unreliable startup API call.
def load_steam_app_list():
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
# API ENDPOINT 1: Steam Review Analysis (/analyze) - UNCHANGED
# -------------------------------------------------------------
@app.route('/analyze', methods=['POST'])
def analyze_steam_reviews_api():
    
    # 1. Get the App ID from the request
    try:
        data = request.get_json()
        APP_ID = data.get('app_id')

        if not APP_ID:
            return jsonify({"error": "Missing 'app_id' in request body. Please provide a Steam App ID."}), 400

    except Exception as e:
        return jsonify({"error": f"Error parsing request: {e}"}), 400

    
    # --- STEPS 1-3: Your Core Logic ---
    all_reviews_text = []
    API_URL = f"https://store.steampowered.com/appreviews/{APP_ID}"
    params = {
        'json': 1, 'language': 'english', 'filter': 'recent',
        'num_per_page': 100, 'cursor': '*'
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
                    if not reviews_on_page: break

                    for review in reviews_on_page:
                        all_reviews_text.append(review['review'])

                    params['cursor'] = data.get('cursor', None)
                    time.sleep(0.5) 
                else: break
            else: break
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
# API ENDPOINT 2: Game Name Search (/search) - NEW LOGIC
# -------------------------------------------------------------
@app.route('/search', methods=['POST'])
def search_game():
    data = request.get_json()
    partial_name = data.get('name', '')
    
    if not partial_name:
        return jsonify({"results": []}), 200

    # We call the reliable Steam Store API directly for the search
    SEARCH_API_URL = "https://store.steampowered.com/api/storesearch"
    
    params = {
        'term': partial_name,
        'l': 'english',
        'cc': 'us',
        'request': 1,
        'query': partial_name,
        'category1': '998', # Filter for Games
        'page': 1,
        'excluded_tags': '21,39,40' # Exclude Early Access, VR, and Software tags
    }

    try:
        response = requests.get(SEARCH_API_URL, params=params, timeout=10)
        response.raise_for_status() 
        
        data = response.json()
        
        # Format the results into the clean list structure your Flutter app expects
        matches = []
        for item in data.get('items', []):
            matches.append({
                "appid": str(item['appid']),
                "name": item['name']
            })
            
        # Limit results to 10
        matches = matches[:10]
        
        return jsonify({"results": matches}), 200
        
    except Exception as e:
        print(f"Error during Steam search API call: {e}")
        return jsonify({"error": "Failed to connect to Steam Search API."}), 500
