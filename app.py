from flask import Flask, request, jsonify
import requests
import time
import json
import re
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
MAX_PAGES = 10 # Default limit for 'recent' filter (10 pages * 100 reviews = 1000)
POSITIVE_THRESHOLD = 0.2
NEGATIVE_THRESHOLD = -0.2

# --- NEW THEMATIC KEYWORDS (Centralized for the API) ---
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
    "longevity", "shelf life"
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

# --- HELPER FUNCTION: RUN SENTIMENT ANALYSIS ON A LIST OF REVIEWS ---
def analyze_theme_reviews(review_list):
    positive_count = 0
    negative_count = 0
    
    for review in review_list:
        vs = analyzer.polarity_scores(review.get('review_text', ''))
        compound_score = vs['compound']

        if compound_score >= POSITIVE_THRESHOLD:
            positive_count += 1
        elif compound_score <= NEGATIVE_THRESHOLD:
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


# -------------------------------------------------------------
# API ENDPOINT 1: Steam Review Analysis (/analyze) - UPDATED
# -------------------------------------------------------------
@app.route('/analyze', methods=['POST'])
def analyze_steam_reviews_api():
    # 1. Get parameters from the request
    try:
        data = request.get_json()
        APP_ID = data.get('app_id')
        # NEW: Filter parameter, defaults to 'recent'
        review_filter = data.get('filter', 'recent') 

        if not APP_ID:
            return jsonify({"error": "Missing 'app_id' in request body."}), 400

    except Exception as e:
        return jsonify({"error": f"Error parsing request: {e}"}), 400

    # 2. Determine Collection Parameters (Bases on filter)
    
    # If filter is 'all', lift the max page limit
    if review_filter == 'all':
        max_pages_to_collect = float('inf')
        steam_api_filter = 'all'
    else:
        max_pages_to_collect = MAX_PAGES
        steam_api_filter = 'recent'
        
    # --- Review Collection Loop ---
    all_reviews_raw = []
    API_URL = f"https://store.steampowered.com/appreviews/{APP_ID}"
    params = {
        'json': 1,
        'language': 'english',
        'filter': steam_api_filter,  # Use the determined filter
        'num_per_page': 100,
        'cursor': '*'
    }

    page_count = 0
    while params['cursor'] and page_count < max_pages_to_collect:
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
                        # Extract data we need for analysis and filtering
                        review_data = {
                            'review_text': review.get('review', ""),
                            # NEW: Extract playtime in hours
                            'playtime_hours': round(review.get('playtime_forever', 0) / 60, 1), 
                            'theme_tags': [] # Placeholder for thematic tags
                        }
                        all_reviews_raw.append(review_data)

                    params['cursor'] = data.get('cursor', None)
                    time.sleep(0.5)
                else:
                    break
            else:
                break
        except Exception:
            break

    # 3. Filtering and Thematic Tagging
    
    # Containers to hold reviews specifically filtered by theme
    themed_reviews = {
        'length': [],
        'grind': [],
        'value': []
    }
    
    # List to be returned to the frontend (only includes themed reviews)
    time_centric_reviews_to_return = [] 
    
    for review in all_reviews_raw:
        is_themed = False
        
        # Check against each thematic pattern and tag the review
        for theme, pattern in ALL_PATTERNS.items():
            if pattern.search(review['review_text']):
                review['theme_tags'].append(theme)
                # Ensure each theme-specific list gets a copy of the review
                themed_reviews[theme].append(review)
                is_themed = True
        
        # Only add reviews that matched at least one theme to the final return list
        if is_themed:
            time_centric_reviews_to_return.append(review)


    # 4. Thematic Sentiment Analysis
    
    # Run the analysis helper function for each thematic list
    length_analysis = analyze_theme_reviews(themed_reviews['length'])
    grind_analysis = analyze_theme_reviews(themed_reviews['grind'])
    value_analysis = analyze_theme_reviews(themed_reviews['value'])

    # 5. Return the result with all new data
    return jsonify({
        "status": "success",
        "app_id": APP_ID,
        "filter_used": review_filter, # The filter used for this analysis
        "total_reviews_collected": len(all_reviews_raw),
        
        # NEW: Thematic Sentiment Scores
        "analysis_results": {
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
        
        # NEW: Raw review data for the frontend display and filtering
        "time_centric_reviews": time_centric_reviews_to_return 
    }), 200


# -------------------------------------------------------------
# API ENDPOINT 2: Game Name Search (/search) - UPDATED FOR IMAGE
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
            # NEW: Extract the header image URL
            header_image = item.get('header_image', '') 

            if game_id and name:
                matches.append({
                    "appid": str(game_id),
                    "name": name,
                    "header_image_url": header_image # Include the image URL
                })

        matches = matches[:10] # Limit results
        return jsonify({"results": matches}), 200

    except Exception as e:
        print(f"Error during Steam search API call: {e}")
        return jsonify({"error": "Failed to connect to Steam Search API."}), 500


# -------------------------------------------------------------
# MAIN ENTRYPOINT
# -------------------------------------------------------------
if __name__ == '__main__':
    # debug=True for development – turn off in production
    app.run(host='0.0.0.0', port=5000, debug=True)
