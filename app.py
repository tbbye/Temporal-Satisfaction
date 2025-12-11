from flask import Flask, request, jsonify 
import requests 
import time
import json 
import re
import nltk
from nltk.sentiment.vader import SentimentIntensityAnalyzer

# --- GLOBAL VARIABLES ---
STEAM_APP_LIST = []

# Initialize Flask app
app = Flask(__name__)

# --- FUNCTION: Load Steam App List ---
def load_steam_app_list():
    """Fetches the full list of Steam games (name and appid) and caches it."""
    global STEAM_APP_LIST
    try:
        # Public Steam API endpoint
        url = "https://api.steampowered.com/ISteamApps/GetAppList/v2/"
        response = requests.get(url, timeout=30)
        response.raise_for_status() # Raise an error for bad status codes
        
        # Extract the list of dictionaries
        data = response.json()
        STEAM_APP_LIST = data['applist']['apps']
        print(f"Successfully loaded {len(STEAM_APP_LIST)} Steam apps.")
    except Exception as e:
        print(f"Error loading Steam app list: {e}")
        STEAM_APP_LIST = []

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
