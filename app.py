from flask import Flask, request, jsonify
import requests
import time
import json
import re
import numpy as np # NEW: Used for calculating statistics like median and percentiles
import nltk
from nltk.sentiment.vader import SentimentIntensityAnalyzer

# --- GLOBAL INITIALIZATION ---
app = Flask(__name__)

# Download VADER lexicon data and initialize globally
try:
    nltk.data.find('sentiment/vader_lexicon.zip')
except LookupError:
    nltk.download('vader_lexicon', quiet=True)

analyzer = SentimentIntensityAnalyzer()

# --- CONFIGURATION (Settings) ---
POSITIVE_THRESHOLD = 0.2
NEGATIVE_THRESHOLD = -0.2
DEFAULT_REVIEW_CHUNK_SIZE = 20 # How many reviews to return per page in the new /reviews endpoint

# --- THEMATIC KEYWORDS (Centralized for the API) ---
LENGTH_KEYWORDS = [
    "hour", "hours", "length", "lengths", "lengthy", "short", "long", 
    "campaign", "time sink", "time investment", "time commitment"
]
GRIND_KEYWORDS = [
    "grind", "grindy", "farming", "farm", "repetitive", "repetition", 
    "burnout", "dailies", "daily", "chore", "time waste"
]
VALUE_KEYWORDS = [
    "worth it", "value for money", "money well spent", "replayable", 
    "replayability", "too short for the price", "content updates", 
    "longevity", "shelf life", "price"
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

# --- HELPER FUNCTION: RUN SENTIMENT ANALYSIS ON A SINGLE REVIEW (FIX 3) ---
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
    
    # NEW: Now relies on the sentiment_label added during collection
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

# --- HELPER FUNCTION: CALCULATE PLAYTIME DISTRIBUTION (FIX 7) ---
def calculate_playtime_distribution(all_reviews):
    playtimes = [r['playtime_hours'] for r in all_reviews if r['playtime_hours'] > 0]
    
    if not playtimes:
        return {
            "median_hours": 0.0, "percentile_25th": 0.0, "percentile_75th": 0.0,
            "interpretation": "Not enough data with recorded playtime to analyze distribution.",
            "histogram_buckets": [0.0] * 5 
        }

    arr = np.array(playtimes)
    
    median = np.median(arr)
    p25 = np.percentile(arr, 25)
    p75 = np.percentile(arr, 75)
    
    # Create Histogram Bins: e.g., 0-1h, 1-5h, 5-20h, 20-50h, 50+h (Adjust as needed)
    bins = [0, 1, 5, 20, 50, arr.max() + 1] 
    hist, _ = np.histogram(arr, bins=bins)
    
    # Interpretation Logic
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
# API ENDPOINT 1: Steam Review Analysis (/analyze) - UPDATED
# -------------------------------------------------------------
# The backend now expects 'review_count' (e.g., 1000, 2000, 3000) (FIX 5)
@app.route('/analyze', methods=['POST'])
def analyze_steam_reviews_api():
    # 1. Get parameters from the request
    try:
        data = request.get_json()
        APP_ID = data.get('app_id')
        # NEW: Expect total review count to fetch (e.g., 1000, 2000)
        review_count = data.get('review_count', 1000) 

        if not APP_ID:
            return jsonify({"error": "Missing 'app_id' in request body."}), 400

    except Exception as e:
        return jsonify({"error": f"Error parsing request: {e}"}), 400

    # 2. Determine Collection Parameters
    MAX_REVIEWS_TO_COLLECT = review_count
    
    # Steam API limitation: 100 reviews per page
    max_pages_to_collect = MAX_REVIEWS_TO_COLLECT // 100
    if MAX_REVIEWS_TO_COLLECT % 100 != 0:
        max_pages_to_collect += 1
    
    # --- Review Collection Loop ---
    all_reviews_raw = []
    API_URL = f"https://store.steampowered.com/appreviews/{APP_ID}"
    params = {
        'json': 1,
        'language': 'english',
        'filter': 'recent',  # Always fetch recent, up to the count
        'num_per_page': 100,
        'cursor': '*'
    }

    page_count = 0
    while params['cursor'] and page_count < max_pages_to_collect:
        page_count += 1
        try:
            response = requests.get(API_URL, params=params, timeout=15) # Increased timeout
            response.raise_for_status() # Raise exception for 4xx or 5xx status codes

            data = response.json()
            if data.get('success') == 1:
                reviews_on_page = data.get('reviews', [])
                if not reviews_on_page or len(all_reviews_raw) >= MAX_REVIEWS_TO_COLLECT:
                    break

                for review in reviews_on_page:
                    if len(all_reviews_raw) >= MAX_REVIEWS_TO_COLLECT:
                        break
                        
                    # Fix 2 & 3: Playtime and Sentiment
                    review_data = {
                        'review_text': review.get('review', ""),
                        # FIX 2: Playtime in minutes (playtime_forever) converted to hours
                        'playtime_hours': round(review.get('playtime_forever', 0) / 60, 1), 
                        # FIX 3: Add sentiment label
                        'sentiment_label': get_review_sentiment(review.get('review', "")),
                        'theme_tags': [] # Placeholder for thematic tags
                    }
                    all_reviews_raw.append(review_data)

                params['cursor'] = data.get('cursor', None)
                time.sleep(0.5)
            else:
                break
        except requests.RequestException as e:
            print(f"API Request Error: {e}")
            break
        except Exception as e:
            print(f"Unexpected Error during collection: {e}")
            break

    # 3. Filtering and Thematic Tagging
    
    # Containers to hold reviews specifically filtered by theme
    themed_reviews = {
        'length': [],
        'grind': [],
        'value': []
    }
    
    # List to hold reviews with thematic tags (used by the new /reviews endpoint for pagination)
    all_themed_reviews = []
    
    for review in all_reviews_raw:
        is_themed = False
        
        # Check against each thematic pattern and tag the review
        for theme, pattern in ALL_PATTERNS.items():
            if pattern.search(review['review_text']):
                review['theme_tags'].append(theme)
                themed_reviews[theme].append(review)
                is_themed = True
        
        if is_themed:
            all_themed_reviews.append(review) # Store the tagged review

    # 4. Thematic Sentiment Analysis & Playtime Distribution
    
    # Run the analysis helper function for each thematic list
    length_analysis = analyze_theme_reviews(themed_reviews['length'])
    grind_analysis = analyze_theme_reviews(themed_reviews['grind'])
    value_analysis = analyze_theme_reviews(themed_reviews['value'])
    
    # FIX 7: Calculate Playtime Distribution
    playtime_distribution = calculate_playtime_distribution(all_reviews_raw)

    # 5. Return the result
    return jsonify({
        "status": "success",
        "app_id": APP_ID,
        "review_count_used": review_count,
        "total_reviews_collected": len(all_reviews_raw),
        
        "thematic_scores": { # Renamed from 'analysis_results' to match Flutter model
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
        
        # FIX 7: Playtime Distribution Data
        "playtime_distribution": playtime_distribution,

        # IMPORTANT: Reviews are NOT returned here. They are saved/cached for the /reviews endpoint.
        # For a production system, you would save all_themed_reviews to a cache (like Redis)
        # using the (APP_ID, review_count) as the key.
        "total_themed_reviews": len(all_themed_reviews), # New field to help the frontend
        
    }), 200


# -------------------------------------------------------------
# API ENDPOINT 2: Game Name Search (/search) - FIX 1: IMAGE URL
# -------------------------------------------------------------
@app.route('/search', methods=['POST'])
def search_game():
    # 1. Parse the incoming JSON
    try:
        data = request.get_json(force=True) or {}
    except Exception as e:
        return jsonify({"error": f"Error parsing JSON body: {e}"}), 400

    partial_name = data.get('name', '').strip()
    if not partial_name:
        return jsonify({"results": []}), 200

    # 2. Use the Steam Store Search API
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
            # FIX 1: The 'header_image' field is available in this API response!
            header_image = item.get('header_image', '') 

            if game_id and name:
                matches.append({
                    "appid": str(game_id),
                    "name": name,
                    "header_image_url": header_image # Corrected field name for Flutter
                })

        matches = matches[:10] # Limit results
        return jsonify({"results": matches}), 200

    except Exception as e:
        print(f"Error during Steam search API call: {e}")
        return jsonify({"error": "Failed to connect to Steam Search API."}), 500


# -------------------------------------------------------------
# API ENDPOINT 3: Paginated Review Fetching (/reviews) - NEW ENDPOINT (FIX 4)
# -------------------------------------------------------------
# NOTE: This endpoint assumes the data (all_themed_reviews from /analyze) is cached.
# For simplicity, we are using a temporary in-memory cache here, which IS NOT
# suitable for production (Render will restart and wipe it).
# Please ensure you implement a proper cache (Redis/DB) for production.
TEMP_REVIEW_CACHE = {} 
CACHE_KEY_FORMAT = "{app_id}_{review_count}"

@app.route('/reviews', methods=['GET'])
def get_paginated_reviews():
    app_id = request.args.get('app_id')
    offset = int(request.args.get('offset', 0))
    limit = int(request.args.get('limit', DEFAULT_REVIEW_CHUNK_SIZE))
    total_count = int(request.args.get('total_count', 1000)) # The total scope of reviews to check

    if not app_id:
        return jsonify({"error": "Missing 'app_id' parameter."}), 400

    cache_key = CACHE_KEY_FORMAT.format(app_id=app_id, review_count=total_count)
    
    # 1. Check if the themed reviews list is in the cache (from the preceding /analyze call)
    themed_reviews_list = TEMP_REVIEW_CACHE.get(cache_key)

    if not themed_reviews_list:
        # If not in cache, the Flutter app needs to call /analyze first.
        return jsonify({"error": "Analysis data not found. Please run /analyze first."}), 404

    # 2. Extract the relevant slice for pagination
    start_index = offset
    end_index = offset + limit
    
    reviews_page = themed_reviews_list[start_index:end_index]
    total_available_themed = len(themed_reviews_list)

    # 3. Return the paginated chunk
    return jsonify({
        "reviews": reviews_page,
        "total_available": total_available_themed,
        "offset": offset,
        "limit": limit
    }), 200


# -------------------------------------------------------------
# MAIN ENTRYPOINT
# -------------------------------------------------------------
if __name__ == '__main_':
    # This must be run with a cache mechanism in mind.
    # We need to monkey-patch the /analyze endpoint to save data to the cache
    @app.after_request
    def cache_reviews_after_analyze(response):
        if request.endpoint == 'analyze_steam_reviews_api' and response.status_code == 200:
            try:
                data = json.loads(response.get_data(as_text=True))
                # Only cache the data structure that holds the themed reviews (which must be computed by /analyze)
                themed_reviews = data.pop('time_centric_reviews', []) 
                
                # We need the parameters used to generate this specific list
                app_id = data.get('app_id')
                review_count = data.get('review_count_used')
                
                if app_id and review_count is not None:
                    cache_key = CACHE_KEY_FORMAT.format(app_id=app_id, review_count=review_count)
                    # Save the FULL list of themed reviews to the cache
                    TEMP_REVIEW_CACHE[cache_key] = themed_reviews 
                    
                # Re-add the total count for the frontend, but keep the list out of the response body (it's too large)
                data['total_themed_reviews'] = len(themed_reviews)
                response.set_data(json.dumps(data))

            except Exception as e:
                # Log any caching errors but do not block the main response
                print(f"Error during post-analysis caching: {e}")
                
        return response

    # debug=True for development – turn off in production
    app.run(host='0.0.0.0', port=5000, debug=True)
