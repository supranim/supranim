# Supranim is a simple Hyper Server and Web Framework developed
# for building safe & fast in-house projects.
# 
# Supranim Server - Botland
# Detects most popular Bots, cralwers and spiders.
# 
# (c) 2021 Supranim is released under MIT License
#          by George Lemon <georgelemon@protonmail.com>
#          
#          Website: https://supranim.com
#          Github Repository: https://github.com/supranim

import re

# A better alternative would be to lookup for IP from request session
# and determine if given IP is part of the following big search engines.
# Baidu   *.crawl.baidu.com
# Baidu   *.crawl.baidu.jp
# Bing    *.search.msn.com
# Googlebot   *.google.com
# Googlebot   *.googlebot.com
# Yahoo   *.crawl.yahoo.net
# Yandex  *.yandex.ru
# Yandex  *.yandex.net
# Yandex  *.yandex.com

var crawlers: seq[string] = @[
        r"Google AppsViewer",
        r"Google Desktop",
        r"Google favicon",
        r"Google Keyword Suggestion",
        r"Google Keyword Tool",
        r"Google Page Speed Insights",
        r"Google-Podcast",
        r"Google PP Default",
        r"Google Search Console",
        r"Google Web Preview",
        r"Google-Ads-Creatives-Assistant",
        r"Google-Ads-Overview",
        r"Google-Adwords",
        r"Google-Apps-Script",
        r"Google-Calendar-Importer",
        r"Google-HotelAdsVerifier",
        r"Google-HTTP-Java-Client",
        r"Google-SMTP-STS",
        r"Google-Publisher-Plugin",
        r"Google-Read-Aloud",
        r"Google-SearchByImage",
        r"Google-Site-Verification",
        r"Google-speakr",
        r"Google-Structured-Data-Testing-Tool",
        r"Google-Youtube-Links",
        r"google-xrawler",
        r"GoogleDocs",
        r"GoogleHC\/",
        r"GoogleProducer",
        r"GoogleSites",
        r"Google-Transparency-Report",
        r"[a-z0-9\-_]*(bot|crawl|archiver|transcoder|spider|uptime|validator|fetcher|cron|checker|reader|extractor|monitoring|analyzer|scraper)",
    ]

proc isBot*(agent: string): bool =
    ## Determine if is a bot by checking the user agent
    ## provided with the request headers
    for crawler in crawlers:
        if agent.find(re(crawler)) != -1:
            return true
    return false
