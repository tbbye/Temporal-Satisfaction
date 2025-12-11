from flask import Flask, request, jsonify # IMPORTS: Flask is required for the web structure
import requests
import time
import json
import re 
import nltk
from nltk.sentiment.vader import SentimentIntensityAnalyzer

# Initialize Flask app
# THIS LINE IS CRITICAL: It creates the 'app' object that Gunicorn looks for!
app = Flask(__name__) 

# Download VADER lexicon data and initialize globally
# This ensures VADER is available on the server during the startup process.
try:
    nltk.data.find('sentiment/vader_lexicon.zip')
except LookupError:
    # If the resource is not found, download it.
    # The LookupError is the correct exception to catch here.
    nltk.download('vader_lexicon', quiet=True)

analyzer = SentimentIntensityAnalyzer()

# --- CONFIGURATION (Settings) ---
MAX_PAGES = 10 
POSITIVE_THRESHOLD = 0.2
NEGATIVE_THRESHOLD = -0.2

# Your Time-Centric Keywords (Expanded and centralized for the API)
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
# THE API ENDPOINT FUNCTION (This is what your mobile app calls)
# -------------------------------------------------------------

# This decorator creates the API URL: /analyze, and specifies it only accepts POST requests
@app.route('/analyze', methods=['POST'])
def analyze_steam_reviews_api():
    
    # 1. Get the App ID from the request
    try:
        # The app will send the App ID in the request body (JSON)
        data = request.get_json()
        APP_ID = data.get('app_id')
        
        if not APP_ID:
            # Returns an error if the App ID is missing
            return jsonify({"error": "Missing 'app_id' in request body. Please provide a Steam App ID."}), 400
            
    except Exception as e:
        return jsonify({"error": f"Error parsing request: {e}"}), 400

    
    # --- STEPS 1-3: Your Core Logic (Inside the API function) ---
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
            # Setting a timeout is important for serverless functions
            response = requests.get(API_URL, params=params, timeout=10) 
            if response.status_code == 200:
                data = response.json()
                if data.get('success') == 1:
                    reviews_on_page = data.get('reviews', [])
                    if not reviews_on_page: break
                        
                    for review in reviews_on_page:
                        all_reviews_text.append(review['review'])
                        
                    params['cursor'] = data.get('cursor', None)
                    time.sleep(0.5) # Reduced sleep for faster server execution
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
    # This returns the data the mobile app needs!
    return jsonify({
        "status": "success",
        "app_id": APP_ID,
        "total_reviews_collected": len(all_reviews_text),
        "time_centric_reviews_found": len(time_centric_reviews),
        "positive_sentiment_percent": round(positive_percent, 2),
        "negative_sentiment_percent": round(negative_percent, 2)
    })
