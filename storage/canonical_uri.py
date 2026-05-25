from urllib.parse import urlparse, urlunparse


def canonicalize_uri(uri: str) -> str:
    p = urlparse(uri)
    host = p.netloc.lower()
    if host.startswith('www.'):
        host = host[4:]
    path = p.path.rstrip('/')
    # Reddit: strip tracking params, normalize subdomain
    if 'reddit.com' in host:
        host = 'reddit.com'
        path = path.split('?')[0]
    # X/Twitter: normalize to x.com
    if host in ('twitter.com', 'x.com', 'mobile.twitter.com', 'www.twitter.com'):
        host = 'x.com'
    # Drop fragment and query for stable form
    return urlunparse((p.scheme, host, path, '', '', ''))
