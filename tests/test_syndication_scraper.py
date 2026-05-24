"""
Tests for the Twitter/X syndication scraper.

Run with: python -m pytest tests/test_syndication_scraper.py -v
Self-test: python -m scraping.x.syndication_scraper --self-test
"""

import asyncio
import json
import math
import pytest
import datetime as dt
from unittest.mock import AsyncMock, MagicMock, patch

from scraping.x.syndication_scraper import (
    SyndicationScraper,
    _get_syndication_token,
    _parse_profile_timeline,
    _syndication_tweet_to_xcontent,
)
from common.data import DataSource


# ─────────────────────── Token algorithm ───────────────────────

class TestTokenAlgorithm:
    def test_returns_digits_only(self):
        token = _get_syndication_token("1629307668568633344")
        assert token.isdigit(), f"Token must be digits only, got: {token!r}"

    def test_nonempty(self):
        token = _get_syndication_token("1629307668568633344")
        assert len(token) > 0

    def test_known_tweet_id(self):
        """Token for tweet 1629307668568633344 must be a stable digit string."""
        token = _get_syndication_token("1629307668568633344")
        # Recompute manually: float(1629307668568633344) / 1e15 * pi, strip non-digits
        id_float = float(int("1629307668568633344"))
        result = id_float / 1e15 * math.pi
        result_str = f"{result:.20f}"
        import re
        expected = re.sub(r"[^0-9]", "", result_str)
        assert token == expected

    def test_different_ids_give_different_tokens(self):
        t1 = _get_syndication_token("1629307668568633344")
        t2 = _get_syndication_token("1234567890123456789")
        assert t1 != t2


# ─────────────────────── Profile timeline parser ───────────────────────

SAMPLE_NEXT_DATA = {
    "props": {
        "pageProps": {
            "timeline": {
                "entries": [
                    {
                        "content": {
                            "tweet": {
                                "id_str": "111",
                                "full_text": "Hello #bitcoin world",
                                "created_at": "Mon Jan 01 12:00:00 +0000 2024",
                                "user": {
                                    "screen_name": "testuser",
                                    "id_str": "999",
                                    "name": "Test User",
                                    "verified": False,
                                    "followers_count": 100,
                                    "friends_count": 50,
                                },
                                "entities": {
                                    "hashtags": [{"text": "bitcoin"}]
                                },
                                "favorite_count": 10,
                                "retweet_count": 2,
                                "lang": "en",
                            }
                        }
                    },
                    {
                        "content": {
                            # Entry without tweet key — should be skipped
                            "other": {}
                        }
                    }
                ]
            }
        }
    }
}


class TestProfileTimelineParser:
    def test_parses_tweets(self):
        html = f'<script id="__NEXT_DATA__" type="application/json">{json.dumps(SAMPLE_NEXT_DATA)}</script>'
        tweets = _parse_profile_timeline(html)
        assert len(tweets) == 1
        assert tweets[0]["id_str"] == "111"

    def test_empty_on_missing_script(self):
        tweets = _parse_profile_timeline("<html><body>No script here</body></html>")
        assert tweets == []

    def test_empty_on_bad_json(self):
        tweets = _parse_profile_timeline('<script id="__NEXT_DATA__" type="application/json">{bad json}</script>')
        assert tweets == []


# ─────────────────────── Tweet → XContent ───────────────────────

SAMPLE_TWEET = {
    "id_str": "111",
    "full_text": "Hello #bitcoin world https://t.co/abc",
    "created_at": "Mon Jan 01 12:00:00 +0000 2024",
    "user": {
        "screen_name": "testuser",
        "id_str": "999",
        "name": "Test User",
        "verified": False,
        "is_blue_verified": True,
        "followers_count": 100,
        "friends_count": 50,
        "description": "Crypto enthusiast",
    },
    "entities": {
        "hashtags": [{"text": "bitcoin"}]
    },
    "favorite_count": 10,
    "retweet_count": 2,
    "reply_count": 1,
    "lang": "en",
}


class TestTweetToXContent:
    def test_basic_fields(self):
        scraped_at = dt.datetime.now(dt.timezone.utc)
        xc = _syndication_tweet_to_xcontent(SAMPLE_TWEET, scraped_at)
        assert xc is not None
        assert xc.username == "@testuser"
        assert xc.tweet_id == "111"
        assert xc.url == "https://x.com/testuser/status/111"

    def test_hashtag_extraction(self):
        scraped_at = dt.datetime.now(dt.timezone.utc)
        xc = _syndication_tweet_to_xcontent(SAMPLE_TWEET, scraped_at)
        assert "#bitcoin" in xc.tweet_hashtags

    def test_timestamp_parsed(self):
        scraped_at = dt.datetime.now(dt.timezone.utc)
        xc = _syndication_tweet_to_xcontent(SAMPLE_TWEET, scraped_at)
        assert xc.timestamp == dt.datetime(2024, 1, 1, 12, 0, 0, tzinfo=dt.timezone.utc)

    def test_like_count(self):
        scraped_at = dt.datetime.now(dt.timezone.utc)
        xc = _syndication_tweet_to_xcontent(SAMPLE_TWEET, scraped_at)
        assert xc.like_count == 10

    def test_returns_none_on_missing_id(self):
        bad_tweet = {**SAMPLE_TWEET, "id_str": "", "id": ""}
        scraped_at = dt.datetime.now(dt.timezone.utc)
        xc = _syndication_tweet_to_xcontent(bad_tweet, scraped_at)
        assert xc is None

    def test_to_data_entity(self):
        scraped_at = dt.datetime.now(dt.timezone.utc)
        xc = _syndication_tweet_to_xcontent(SAMPLE_TWEET, scraped_at)
        entity = xc.to_data_entity(xc)
        assert entity.source == DataSource.X
        assert "x.com/testuser/status/111" in entity.uri
        assert entity.label.value == "#bitcoin"


# ─────────────────────── Scraper validate ───────────────────────

class TestSyndicationScraperValidate:
    """Tests for the validate() method using mocked HTTP calls."""

    def _make_entity(self, tweet_id="111", username="testuser"):
        """Create a minimal DataEntity for a tweet."""
        scraped_at = dt.datetime.now(dt.timezone.utc)
        xc = _syndication_tweet_to_xcontent(SAMPLE_TWEET, scraped_at)
        return xc.to_data_entity(xc)

    @pytest.mark.asyncio
    async def test_validate_live_tweet_pass(self):
        scraper = SyndicationScraper()
        entity = self._make_entity()

        with patch.object(scraper, "_fetch_single_tweet", return_value=SAMPLE_TWEET):
            results = await scraper.validate([entity])

        assert len(results) == 1
        assert results[0].is_valid

    @pytest.mark.asyncio
    async def test_validate_deleted_tweet_pass(self):
        """Deleted tweets (404) should pass as tweet_deleted_post_capture."""
        scraper = SyndicationScraper()
        entity = self._make_entity()

        with patch.object(scraper, "_fetch_single_tweet", return_value=None):
            results = await scraper.validate([entity])

        assert len(results) == 1
        assert results[0].is_valid
        assert "deleted" in results[0].reason

    @pytest.mark.asyncio
    async def test_validate_username_mismatch_fail(self):
        scraper = SyndicationScraper()
        entity = self._make_entity()

        wrong_tweet = {**SAMPLE_TWEET, "user": {**SAMPLE_TWEET["user"], "screen_name": "otheruser"}}
        with patch.object(scraper, "_fetch_single_tweet", return_value=wrong_tweet):
            results = await scraper.validate([entity])

        assert len(results) == 1
        assert not results[0].is_valid
        assert "mismatch" in results[0].reason.lower()
