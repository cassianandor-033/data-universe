import unittest

from storage.canonical_uri import canonicalize_uri


class TestCanonicalizeUri(unittest.TestCase):

    def test_reddit_strips_tracking_params_and_www(self):
        uri = "https://www.reddit.com/r/bitcoin/comments/abc/?utm_source=share"
        self.assertEqual(
            canonicalize_uri(uri),
            "https://reddit.com/r/bitcoin/comments/abc",
        )

    def test_reddit_old_subdomain_normalized(self):
        # old.reddit.com contains 'reddit.com' so subdomain is stripped
        uri = "https://old.reddit.com/r/ethereum/comments/xyz/"
        self.assertEqual(
            canonicalize_uri(uri),
            "https://reddit.com/r/ethereum/comments/xyz",
        )

    def test_twitter_normalized_to_x(self):
        uri = "https://twitter.com/user/status/12345"
        self.assertEqual(
            canonicalize_uri(uri),
            "https://x.com/user/status/12345",
        )

    def test_mobile_twitter_normalized_to_x(self):
        uri = "https://mobile.twitter.com/user/status/99"
        self.assertEqual(
            canonicalize_uri(uri),
            "https://x.com/user/status/99",
        )

    def test_x_com_unchanged(self):
        uri = "https://x.com/user/status/42"
        self.assertEqual(
            canonicalize_uri(uri),
            "https://x.com/user/status/42",
        )

    def test_trailing_slash_stripped(self):
        uri = "https://x.com/user/status/42/"
        self.assertEqual(
            canonicalize_uri(uri),
            "https://x.com/user/status/42",
        )

    def test_fragment_dropped(self):
        uri = "https://x.com/user/status/42#replies"
        self.assertEqual(
            canonicalize_uri(uri),
            "https://x.com/user/status/42",
        )

    def test_query_dropped_for_non_reddit(self):
        uri = "https://x.com/user/status/42?s=20"
        self.assertEqual(
            canonicalize_uri(uri),
            "https://x.com/user/status/42",
        )

    def test_host_lowercased(self):
        uri = "https://Reddit.com/r/Bitcoin/comments/abc"
        self.assertEqual(
            canonicalize_uri(uri),
            "https://reddit.com/r/Bitcoin/comments/abc",
        )


if __name__ == "__main__":
    unittest.main()
