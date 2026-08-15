# Supranim is a lightweight, high-performance MVC framework for Nim,
# designed to simplify the development of web applications and REST APIs.
#
# It features intuitive routing, modular architecture, and built-in support
# for modern web standards, making it easy to build scalable and maintainable
# projects.
#
# (c) 2025 Supranim | MIT License
#     Made by Humans from OpenPeeps
#     https://supranim.com | https://github.com/supranim

## HTTP/1.1 client for Supranim, backed by powpow's internal `HttpClient`.
##
## This module re-exports `pkg/powpow/proto/httpclient` so Supranim code can
## use a single, stable import path. Both the blocking `HttpClient` and the
## await-able `AsyncHttpClient` are provided; Unix domain socket support
## (POSIX only) and Windows are handled by powpow itself.

import pkg/powpow/proto/httpclient

export httpclient
