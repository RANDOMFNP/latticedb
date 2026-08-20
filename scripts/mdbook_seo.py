#!/usr/bin/env python3
"""Post-process the mdBook build output for search engines.

mdBook produces good HTML but leaves four things on the table, and Cloudflare
Pages adds a fifth:

  1. Every internal link ends in ``.html``. Cloudflare Pages serves clean URLs
     and 308-redirects every ``.html`` request, so each link costs a redirect
     hop before it resolves.
  2. There is no per-page description -- every page inherits the single
     ``description`` from book.toml.
  3. There are no canonical tags.
  4. The navbar renders the site title as a second ``<h1>``, competing with the
     page's own heading.
  5. ``print.html`` is a concatenation of every page in the book, which is a
     duplicate of the entire site unless it is marked noindex.

This script fixes all of that in the build directory, then writes a sitemap and
robots.txt. It is idempotent: running it twice on the same build is a no-op.

Usage:
    scripts/mdbook_seo.py --build-dir book/build --src-dir book/src \\
        --base-url https://docs.latticedb.org

``searchindex.js`` is deliberately left untouched. Its URLs are only followed by
the client-side search box, never by a crawler, so rewriting them would add risk
without adding any search-engine benefit.
"""

from __future__ import annotations

import argparse
import html
import json
import re
import subprocess
import sys
from datetime import date, datetime, timezone
from pathlib import Path

# Pages that exist for humans or browsers but must never rank.
NOINDEX_PAGES = {"404.html", "print.html"}

# The share image lives on the marketing site; the docs reuse it.
OG_IMAGE = "https://latticedb.org/assets/og-card.png"

MAX_DESCRIPTION = 160

ABSOLUTE_HREF = re.compile(r"^(?:[a-z][a-z0-9+.-]*:|//|#)", re.I)
HREF_ATTR = re.compile(r'(\shref=")([^"]+)(")')
HTML_SUFFIX = re.compile(r"^([^#?]*?)\.html([#?].*)?$")

DESCRIPTION_META = re.compile(
    r'\s*<meta\s+name="description"\s+content="[^"]*">\s*\n?', re.I
)
TITLE_TAG = re.compile(r"<title>(.*?)</title>", re.S | re.I)
ROBOTS_META = re.compile(r'<meta\s+name="robots"', re.I)
MENU_TITLE_H1 = re.compile(r'<h1(\s+class="menu-title")>(.*?)</h1>', re.S)

MARKER = "<!-- seo: mdbook_seo.py -->"


# --------------------------------------------------------------------------- #
# URL helpers
# --------------------------------------------------------------------------- #


def clean_href(href: str) -> str:
    """Strip the ``.html`` extension from a relative link.

    ``foo/bar.html``      -> ``foo/bar``
    ``../index.html#anc`` -> ``../#anc``
    ``index.html``        -> ``./``

    Absolute URLs, protocol-relative URLs, and bare fragments pass through
    untouched. Stripping the extension preserves directory depth, so relative
    links inside the page keep resolving to the same targets.
    """
    if ABSOLUTE_HREF.match(href):
        return href
    match = HTML_SUFFIX.match(href)
    if not match:
        return href
    base, tail = match.group(1), match.group(2) or ""
    if base.endswith("index"):
        base = base[: -len("index")] or "./"
    return base + tail


def canonical_path(relative: Path) -> str:
    """Map a built file to the path Cloudflare Pages will actually serve."""
    parts = relative.as_posix()
    if parts == "index.html":
        return "/"
    if parts.endswith("/index.html"):
        return "/" + parts[: -len("index.html")]
    return "/" + parts[: -len(".html")]


# --------------------------------------------------------------------------- #
# Description extraction
# --------------------------------------------------------------------------- #

MD_IMAGE = re.compile(r"!\[[^\]]*\]\([^)]*\)")
MD_LINK = re.compile(r"\[([^\]]*)\]\([^)]*\)")
MD_EMPHASIS = re.compile(r"(\*\*|__|\*|_|`)")
MD_HTML_TAG = re.compile(r"</?[a-zA-Z][^>]*>")


def first_paragraph(markdown: str) -> str:
    """Return the first real prose paragraph of a Markdown document."""
    lines = markdown.splitlines()
    buffer: list[str] = []
    in_fence = False

    for raw in lines:
        line = raw.rstrip()
        stripped = line.strip()

        if stripped.startswith("```") or stripped.startswith("~~~"):
            in_fence = not in_fence
            if buffer:
                break
            continue
        if in_fence:
            continue

        if not stripped:
            if buffer:
                break
            continue

        # Skip headings, blockquotes, tables, lists, and directives before the
        # first paragraph -- none of them read well as a search snippet.
        if re.match(r"^(#{1,6}\s|>|\||[-*+]\s|\d+\.\s|<|\{\{)", stripped):
            if buffer:
                break
            continue

        buffer.append(stripped)

    return " ".join(buffer)


def to_description(text: str, fallback: str) -> str:
    """Turn a Markdown paragraph into a clean meta description."""
    text = MD_IMAGE.sub("", text)
    text = MD_LINK.sub(r"\1", text)
    text = MD_HTML_TAG.sub("", text)
    text = MD_EMPHASIS.sub("", text)
    text = html.unescape(text)
    text = re.sub(r"\s+", " ", text).strip()

    if not text:
        return fallback
    if len(text) <= MAX_DESCRIPTION:
        return text

    window = text[:MAX_DESCRIPTION]
    # Prefer cutting at a sentence boundary, then at a word boundary.
    sentence_end = max(window.rfind(". "), window.rfind("! "), window.rfind("? "))
    if sentence_end > MAX_DESCRIPTION // 2:
        return window[: sentence_end + 1]
    word_end = window.rfind(" ")
    if word_end > 0:
        return window[:word_end].rstrip(",;:") + "..."
    return window


# --------------------------------------------------------------------------- #
# Git metadata
# --------------------------------------------------------------------------- #


def git_last_modified(path: Path, repo_root: Path) -> str | None:
    """Return the ISO date of the last commit touching *path*, if available."""
    try:
        result = subprocess.run(
            ["git", "log", "-1", "--format=%cs", "--", str(path)],
            cwd=repo_root,
            capture_output=True,
            text=True,
            timeout=15,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if result.returncode != 0:
        return None
    stamp = result.stdout.strip()
    return stamp or None


# --------------------------------------------------------------------------- #
# HTML rewriting
# --------------------------------------------------------------------------- #


def build_head_block(
    *,
    url: str,
    title: str,
    description: str,
    is_index: bool,
    noindex: bool,
    has_robots_meta: bool,
) -> str:
    """Assemble the tags injected into <head>."""
    esc = lambda value: html.escape(value, quote=True)  # noqa: E731
    lines = [f"        {MARKER}"]

    if noindex and not has_robots_meta:
        lines.append('        <meta name="robots" content="noindex, follow">')

    lines += [
        f'        <link rel="canonical" href="{esc(url)}">',
        f'        <meta name="description" content="{esc(description)}">',
        '        <meta property="og:type" content="{}">'.format(
            "website" if is_index else "article"
        ),
        f'        <meta property="og:url" content="{esc(url)}">',
        '        <meta property="og:site_name" content="LatticeDB Documentation">',
        f'        <meta property="og:title" content="{esc(title)}">',
        f'        <meta property="og:description" content="{esc(description)}">',
        f'        <meta property="og:image" content="{OG_IMAGE}">',
        '        <meta name="twitter:card" content="summary_large_image">',
        f'        <meta name="twitter:title" content="{esc(title)}">',
        f'        <meta name="twitter:description" content="{esc(description)}">',
        f'        <meta name="twitter:image" content="{OG_IMAGE}">',
    ]

    if not noindex:
        structured = {
            "@context": "https://schema.org",
            "@type": "TechArticle",
            "headline": title,
            "description": description,
            "url": url,
            "inLanguage": "en",
            "isPartOf": {
                "@type": "WebSite",
                "name": "LatticeDB Documentation",
                "url": "https://docs.latticedb.org/",
            },
            # Ties every documentation page back to the one software entity
            # declared on latticedb.org, which is what lets search engines tell
            # this LatticeDB apart from the unrelated projects sharing the name.
            "about": {"@id": "https://latticedb.org/#latticedb"},
            "author": {"@type": "Person", "name": "Jeff Hajewski"},
        }
        payload = json.dumps(structured, indent=2)
        payload = payload.replace("<", "\\u003c").replace(">", "\\u003e")
        lines.append('        <script type="application/ld+json">')
        lines.append(payload)
        lines.append("        </script>")

    return "\n".join(lines) + "\n"


def process_page(
    path: Path,
    build_dir: Path,
    src_dir: Path,
    base_url: str,
    book_description: str,
) -> None:
    original = path.read_text(encoding="utf-8")
    if MARKER in original:
        return  # already processed

    text = original
    relative = path.relative_to(build_dir)
    name = relative.as_posix()
    noindex = name in NOINDEX_PAGES

    # 1. Clean up every internal link so it no longer triggers a 308.
    text = HREF_ATTR.sub(lambda m: m.group(1) + clean_href(m.group(2)) + m.group(3), text)

    # 2. Demote the navbar site title so each page has exactly one <h1>.
    text = MENU_TITLE_H1.sub(r"<div\1>\2</div>", text)

    # 3. Work out the page title and description.
    title_match = TITLE_TAG.search(text)
    title = html.unescape(title_match.group(1).strip()) if title_match else "LatticeDB Documentation"

    source = src_dir / relative.with_suffix(".md")
    if source.is_file():
        description = to_description(
            first_paragraph(source.read_text(encoding="utf-8")), book_description
        )
    else:
        description = book_description

    url = base_url.rstrip("/") + canonical_path(relative)

    # 4. Replace the inherited description and inject the rest of the head.
    text = DESCRIPTION_META.sub("\n", text, count=1)
    head_block = build_head_block(
        url=url,
        title=title,
        description=description,
        is_index=(name == "index.html"),
        noindex=noindex,
        has_robots_meta=ROBOTS_META.search(text) is not None,
    )
    text = text.replace("</head>", head_block + "    </head>", 1)

    if text != original:
        path.write_text(text, encoding="utf-8")


# --------------------------------------------------------------------------- #
# Sitemap and robots
# --------------------------------------------------------------------------- #


def write_sitemap(
    pages: list[tuple[Path, str]],
    build_dir: Path,
    src_dir: Path,
    base_url: str,
    repo_root: Path,
) -> int:
    today = date.today().isoformat()
    entries = []

    for relative, url in sorted(pages, key=lambda item: item[1]):
        source = src_dir / relative.with_suffix(".md")
        lastmod = git_last_modified(source, repo_root) if source.is_file() else None
        lastmod = lastmod or today
        priority = "1.0" if relative.as_posix() == "index.html" else "0.7"
        entries.append(
            "  <url>\n"
            f"    <loc>{html.escape(url, quote=False)}</loc>\n"
            f"    <lastmod>{lastmod}</lastmod>\n"
            f"    <priority>{priority}</priority>\n"
            "  </url>"
        )

    generated = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    document = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        f"<!-- Generated by scripts/mdbook_seo.py on {generated}. Do not edit by hand. -->\n"
        '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'
        + "\n".join(entries)
        + "\n</urlset>\n"
    )
    (build_dir / "sitemap.xml").write_text(document, encoding="utf-8")
    return len(entries)


def write_robots(build_dir: Path, base_url: str) -> None:
    body = f"""# {base_url}/robots.txt

User-agent: *
Allow: /

# print.html is a concatenation of the whole book. It stays crawlable so that
# its noindex directive is visible; disallowing it here would hide that.

Sitemap: {base_url}/sitemap.xml
"""
    (build_dir / "robots.txt").write_text(body, encoding="utf-8")


# --------------------------------------------------------------------------- #


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", default="book/build", type=Path)
    parser.add_argument("--src-dir", default="book/src", type=Path)
    parser.add_argument("--base-url", default="https://docs.latticedb.org")
    parser.add_argument(
        "--book-description",
        default="The embedded knowledge graph for AI",
        help="Fallback description for pages with no usable opening paragraph.",
    )
    args = parser.parse_args()

    build_dir: Path = args.build_dir.resolve()
    src_dir: Path = args.src_dir.resolve()
    base_url: str = args.base_url.rstrip("/")

    if not build_dir.is_dir():
        print(f"error: build directory not found: {build_dir}", file=sys.stderr)
        return 1

    repo_root = Path(__file__).resolve().parent.parent

    indexable: list[tuple[Path, str]] = []
    for path in sorted(build_dir.rglob("*.html")):
        relative = path.relative_to(build_dir)
        process_page(path, build_dir, src_dir, base_url, args.book_description)
        if relative.as_posix() not in NOINDEX_PAGES:
            indexable.append((relative, base_url + canonical_path(relative)))

    count = write_sitemap(indexable, build_dir, src_dir, base_url, repo_root)
    write_robots(build_dir, base_url)

    print(f"mdbook_seo: processed {len(indexable)} indexable pages")
    print(f"mdbook_seo: wrote sitemap.xml with {count} URLs")
    print("mdbook_seo: wrote robots.txt")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
