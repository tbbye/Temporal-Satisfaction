from flask import Flask, request, jsonify # IMPORTS: Flask is required for the web structure
import requests # <-- ADDED: Needed for calling the Steam App List API
import time
import json # <-- ALREADY PRESENT
import re
import nltk
from nltk.sentiment.vader import SentimentIntensityAnalyzer

# --- NEW BLOCK 1: Global Variable to store the app list ---
STEAM_APP_LIST = []

# Initialize Flask app
# THIS LINE IS CRITICAL: It creates the 'app' object that Gunicorn looks for!
app = Flask(__name__)

# --- NEW BLOCK 2: Function to load the App List when the server starts ---
def load_steam_app_list():
    """Fetches the full list of Steam games (name and appid) and caches it."""
    global STEAM_APP_LIST
    try:
        # This is a public, official Steam API endpoint for the full app list
        url = "https://api.steampowered.com/ISteamApps/GetAppList/v2/"
        # Use requests, which was imported at the top
        response = requests.get(url, timeout=30)
        response.raise_for_status() # Raise an error for bad status codes
        
        # The list is deeply nested, so we extract the actual list of dictionaries
        data = response.json()
        STEAM_APP_LIST = data['applist']['apps']
        print(f"Successfully loaded {len(STEAM_APP_LIST)} Steam apps.")
    except Exception as e:
        print(f"Error loading Steam app list: {e}")
        STEAM_APP_LIST = [] # Ensure it's empty if it fails

# Call the function when the server starts up (outside of a function/route)
load_steam_app_list()
# --- END NEW BLOCK 2 ---


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
# THE API ENDPOINT FUNCTION (Your original function)
# -------------------------------------------------------------

# This decorator creates the API URL: /analyze, and specifies it only accepts POST requests
@app.route('/analyze', methods=['POST'])
def analyze
