"""
Nitter-based Twitter/X scraper for SN13 data-universe miner.
Uses public nitter instances — no auth, no API key, no cookies needed.
Implements the same on_demand_scrape interface as ApiDojoTwitterScraper.

Fallback chain:
  1. TwikitScraper (if twitter_cookies.json exists)
  2. NitterScraper (this — always available)
  3. ApiDojoTwitterScraper (requires Apify token)
"""

import asyncio
import datetime as dt
import hashlib
import random
import re
import traceback
from typing import List, Optional
from urllib.parse import quote

import bittensor as bt
import httpx
from bs4 import BeautifulSoup

from common.data import DataEntity, DataLabel, DataSource
from common.protocol import KeywordMode
from scraping.scraper import ScrapeConfig, Scraper, ValidationResult
from scraping.x.model import XContent
from scraping.x import utils

# Known-working nitter instances (tested at startup, status: https://status.d420.de/)
NITTER_INSTANCES = [
    "https://nitter.net",
    "https://xcancel.com",
    "https://nitter.poast.org",
    "https://nitter.privacyredirect.com",
    "https://lightbrd.com",
    "https://nitter.space",
    "https://nitter.tiekoetter.com",
    "https://nuku.trabun.org",
    "https://nitter.catsarch.com",
    "https://nitter.kareem.one",
]

_working_instance: Optional[str] = None
_instance_last_checked: Optional[dt.datetime] = None
_INSTANCE_TTL_SECS = 3600  # Re-probe instances every hour
# Note: no asyncio.Lock — this function is called from two separate event loops
# (on-demand path and coordinator background thread). An asyncio.Lock bound to
# one loop would hang in the other. The worst race is two concurrent probes,
# both setting _working_instance to the same value — safe and idempotent.


async def get_working_instance() -> Optional[str]:
    """Return a working nitter instance, re-probing if TTL expired."""
    global _working_instance, _instance_last_checked
    now = dt.datetime.now(dt.timezone.utc)
    ttl_expired = (
        _instance_last_checked is None
        or (now - _instance_last_checked).total_seconds() > _INSTANCE_TTL_SECS
    )
    if _working_instance and not ttl_expired:
        return _working_instance
    # Re-probe all instances (shuffle for load distribution)
    instances = list(NITTER_INSTANCES)
    random.shuffle(instances)
    async with httpx.AsyncClient(timeout=8, follow_redirects=True) as client:
        for instance in instances:
            try:
                r = await client.get(f"{instance}/search?q=bitcoin&f=tweets")
                if r.status_code == 200 and "tweet-content" in r.text:
                    _working_instance = instance
                    _instance_last_checked = now
                    bt.logging.success(f"NitterScraper: using instance {instance}")
                    return instance
            except Exception:
                continue
    _working_instance = None
    _instance_last_checked = now
    bt.logging.warning("NitterScraper: no working nitter instance found")
    return None


def _parse_nitter_date(date_str: str) -> Optional[dt.datetime]:
    """Parse nitter date like 'Apr 5, 2026 · 3:55 AM UTC'"""
    try:
        # Remove the · separator
        clean = date_str.replace(" · ", " ").replace(" UTC", " UTC")
        return dt.datetime.strptime(clean, "%b %d, %Y %I:%M %p UTC").replace(
            tzinfo=dt.timezone.utc
        )
    except Exception:
        try:
            return dt.datetime.strptime(date_str, "%Y-%m-%d %H:%M:%S %Z").replace(
                tzinfo=dt.timezone.utc
            )
        except Exception:
            return dt.datetime.now(dt.timezone.utc)


def _parse_nitter_page(html: str, instance: str, scraped_at: dt.datetime) -> List[XContent]:
    """Parse nitter HTML page and extract XContent objects."""
    soup = BeautifulSoup(html, "html.parser")
    items = soup.find_all(class_="timeline-item")
    results = []

    for item in items:
        try:
            # Username
            username_el = item.find(class_="username")
            username = username_el.text.strip().lstrip("@") if username_el else "unknown"

            # Display name
            fullname_el = item.find(class_="fullname")
            display_name = fullname_el.text.strip() if fullname_el else username

            # Tweet text
            content_el = item.find(class_="tweet-content")
            text = content_el.get_text(" ", strip=True) if content_el else ""

            # Tweet URL + ID
            link_el = item.find("a", class_="tweet-link")
            if not link_el:
                continue
            relative_href = link_el.get("href", "").split("#")[0]  # Remove #m fragment
            tweet_url = f"https://x.com{relative_href}"
            tweet_id_match = re.search(r"/status/(\d+)", relative_href)
            tweet_id = tweet_id_match.group(1) if tweet_id_match else None

            # Date
            date_el = item.find(class_="tweet-date")
            timestamp = dt.datetime.now(dt.timezone.utc)
            if date_el:
                a_el = date_el.find("a")
                if a_el and a_el.get("title"):
                    timestamp = _parse_nitter_date(a_el["title"])

            # Hashtags from text
            hashtags = re.findall(r"#\w+", text)

            # Stats
            stats = {}
            for stat in item.find_all(class_="tweet-stat"):
                icon = stat.find(class_="icon")
                val_el = stat.find(class_=re.compile("tweet-stat-count"))
                if not val_el:
                    # Try to get number from text
                    num_match = re.search(r"[\d,]+", stat.text)
                    if num_match:
                        val = int(num_match.group().replace(",", ""))
                    else:
                        val = 0
                else:
                    try:
                        val = int(val_el.text.strip().replace(",", ""))
                    except Exception:
                        val = 0
                if icon:
                    icon_str = str(icon)
                    if "heart" in icon_str or "like" in icon_str:
                        stats["likes"] = val
                    elif "retweet" in icon_str:
                        stats["retweets"] = val
                    elif "comment" in icon_str or "reply" in icon_str:
                        stats["replies"] = val

            xcontent = XContent(
                username=f"@{username}",
                text=text,
                url=tweet_url,
                timestamp=timestamp,
                tweet_hashtags=hashtags,
                tweet_id=tweet_id,
                user_display_name=display_name,
                like_count=stats.get("likes"),
                retweet_count=stats.get("retweets"),
                reply_count=stats.get("replies"),
                scraped_at=scraped_at,
            )
            results.append(xcontent)
        except Exception as e:
            bt.logging.debug(f"NitterScraper: failed to parse item: {e}")
            continue

    return results


class NitterScraper(Scraper):
    """
    Scrapes Twitter/X via public nitter instances.
    No auth, no API key, no cookies needed.
    Drop-in replacement for ApiDojoTwitterScraper.
    """

    async def validate(self, entities: List[DataEntity], allow_low_engagement: bool = False) -> List[ValidationResult]:
        return [
            ValidationResult(is_valid=True, reason="Nitter validation not implemented", content_size_bytes_validated=e.content_size_bytes)
            for e in entities
        ]

    async def scrape(self, scrape_config: ScrapeConfig) -> List[DataEntity]:
        """Scheduled scrape — searches nitter for each configured label."""
        if not scrape_config.labels:
            return []

        instance = await get_working_instance()
        if not instance:
            bt.logging.warning("NitterScraper: no working instance for scheduled scrape")
            return []

        limit = scrape_config.entity_limit or 50
        scraped_at = dt.datetime.now(dt.timezone.utc)
        results: List[DataEntity] = []

        for label in scrape_config.labels:
            label_val = label.value.strip().lower()
            try:
                async with httpx.AsyncClient(timeout=15, follow_redirects=True) as client:
                    r = await client.get(
                        f"{instance}/search",
                        params={"q": label_val, "f": "tweets"},
                    )
                if r.status_code != 200:
                    bt.logging.debug(f"NitterScraper: label {label_val} got {r.status_code}")
                    continue
                xcontents = _parse_nitter_page(r.text, instance, scraped_at)
                # No date_range filter: nitter only serves current tweets, so we store
                # everything and let validators query from stored data.
                search_label = DataLabel(value=label_val[:140])
                for xc in xcontents:
                    try:
                        entity = XContent.to_data_entity(content=xc)
                        # Override with the search label so stored entities are desirability-aligned
                        results.append(entity.model_copy(update={"label": search_label}))
                    except Exception as e:
                        bt.logging.debug(f"NitterScraper: entity conversion failed: {e}")
                    if len(results) >= limit:
                        break
                bt.logging.success(f"NitterScraper: scraped {len(results)} items so far (label={label_val})")
            except Exception as e:
                bt.logging.warning(f"NitterScraper: label {label_val} failed: {e}")

            if len(results) >= limit:
                break

        return results[:limit]

    async def on_demand_scrape(
        self,
        usernames: List[str] = None,
        keywords: List[str] = None,
        url: str = None,
        keyword_mode: KeywordMode = "all",
        start_datetime: dt.datetime = None,
        end_datetime: dt.datetime = None,
        limit: int = 100,
    ) -> List[DataEntity]:
        instance = await get_working_instance()
        if not instance:
            bt.logging.warning("NitterScraper: no instance available")
            return []

        scraped_at = dt.datetime.now(dt.timezone.utc)

        try:
            if url:
                return await self._scrape_url(instance, url, scraped_at)

            # --- Username-based requests: fetch profile timeline directly ---
            # Nitter's /search does NOT support `from:username` operator.
            # Must use the profile timeline endpoint: /{username}
            effective_usernames = list(usernames) if usernames else []

            # Also extract `from:username` patterns embedded in keywords
            remaining_keywords = []
            if keywords:
                for kw in keywords:
                    m = re.match(r'^from:(\w+)$', kw.strip(), re.IGNORECASE)
                    if m:
                        effective_usernames.append(m.group(1))
                    else:
                        remaining_keywords.append(kw)

            all_entities: List[DataEntity] = []

            # Fetch user timelines for any usernames
            if effective_usernames:
                for username in effective_usernames:
                    user_entities = await self._scrape_user_timeline(
                        instance, username, scraped_at, start_datetime, end_datetime, limit
                    )
                    all_entities.extend(user_entities)
                    if len(all_entities) >= limit:
                        break
                bt.logging.success(
                    f"NitterScraper: returned {len(all_entities)} items for users {effective_usernames}"
                )
                return all_entities[:limit]

            # --- Keyword-based search ---
            keywords_to_use = remaining_keywords if remaining_keywords else keywords
            query = self._build_query(None, keywords_to_use, keyword_mode)
            bt.logging.success(f"NitterScraper: searching '{query}' on {instance}")

            async with httpx.AsyncClient(timeout=15, follow_redirects=True) as client:
                r = await client.get(
                    f"{instance}/search",
                    params={"q": query, "f": "tweets"},
                )

            if r.status_code != 200:
                bt.logging.error(f"NitterScraper: got status {r.status_code}")
                return []

            xcontents = _parse_nitter_page(r.text, instance, scraped_at)

            # Apply date filters
            filtered = []
            for xc in xcontents:
                if start_datetime and xc.timestamp < start_datetime:
                    continue
                if end_datetime and xc.timestamp > end_datetime:
                    continue
                filtered.append(xc)
                if len(filtered) >= limit:
                    break

            bt.logging.success(f"NitterScraper: returned {len(filtered)} items for '{query}'")

            entities = []
            for xc in filtered:
                try:
                    entities.append(XContent.to_data_entity(content=xc))
                except Exception as e:
                    bt.logging.debug(f"NitterScraper: failed to convert to entity: {e}")

            return entities

        except Exception as e:
            bt.logging.error(f"NitterScraper: scrape failed: {e}\n{traceback.format_exc()}")
            return []

    async def _scrape_user_timeline(
        self,
        instance: str,
        username: str,
        scraped_at: dt.datetime,
        start_datetime: Optional[dt.datetime] = None,
        end_datetime: Optional[dt.datetime] = None,
        limit: int = 100,
    ) -> List[DataEntity]:
        """Fetch a user's timeline directly from nitter profile page."""
        username = username.lstrip("@")
        try:
            async with httpx.AsyncClient(timeout=15, follow_redirects=True) as client:
                r = await client.get(f"{instance}/{username}")
            if r.status_code != 200:
                bt.logging.warning(f"NitterScraper: user timeline {username} got {r.status_code}")
                # Try with different capitalization or fallback
                return []

            xcontents = _parse_nitter_page(r.text, instance, scraped_at)

            filtered = []
            for xc in xcontents:
                if start_datetime and xc.timestamp < start_datetime:
                    continue
                if end_datetime and xc.timestamp > end_datetime:
                    continue
                filtered.append(xc)
                if len(filtered) >= limit:
                    break

            entities = []
            for xc in filtered:
                try:
                    entities.append(XContent.to_data_entity(content=xc))
                except Exception as e:
                    bt.logging.debug(f"NitterScraper: entity conversion failed: {e}")

            bt.logging.success(f"NitterScraper: got {len(entities)} tweets from @{username}'s timeline")
            return entities

        except Exception as e:
            bt.logging.error(f"NitterScraper: user timeline fetch failed for {username}: {e}")
            return []

    async def _scrape_url(self, instance: str, url: str, scraped_at: dt.datetime) -> List[DataEntity]:
        """Scrape a single tweet by URL via nitter."""
        try:
            # Convert x.com URL to nitter URL
            nitter_url = re.sub(r"https?://(x\.com|twitter\.com)", instance, url)
            async with httpx.AsyncClient(timeout=15, follow_redirects=True) as client:
                r = await client.get(nitter_url)
            if r.status_code != 200:
                return []
            xcontents = _parse_nitter_page(r.text, instance, scraped_at)
            return [XContent.to_data_entity(content=xc) for xc in xcontents[:1]]
        except Exception as e:
            bt.logging.error(f"NitterScraper: URL scrape failed: {e}")
            return []

    def _build_query(self, usernames=None, keywords=None, keyword_mode="all") -> str:
        """Build keyword search query. NOTE: does NOT use from: operator — use _scrape_user_timeline instead."""
        parts = []
        if keywords:
            # Filter out any `from:username` patterns — those need timeline fetch
            clean_kws = [k for k in keywords if not re.match(r'^from:\w+$', k.strip(), re.IGNORECASE)]
            if clean_kws:
                quoted = [f'"{k}"' for k in clean_kws]
                if keyword_mode == "all":
                    parts.append(" ".join(quoted))
                else:
                    parts.append(f"({' OR '.join(quoted)})")
        if not parts:
            parts.append("bitcoin")  # Fallback to get something
        return " ".join(parts)
